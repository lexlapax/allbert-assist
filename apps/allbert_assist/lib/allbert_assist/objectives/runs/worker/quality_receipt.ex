defmodule AllbertAssist.Objectives.Runs.Worker.QualityReceipt do
  @moduledoc """
  Builds and verifies the content-free receipt for one worker result.

  A receipt binds identity, the exact task contract, the physical provider call
  count, and the accepted answer bytes. It grants no action, effect, permission,
  status transition, or report authority by itself.

  v1.3 M9.b.6 (ADR 0021 A24) writes v3: one generation call, no critic phases.
  v1 stays a byte-exact read/replay path because it shipped. v2 was the
  phase-separated critic shape; it never shipped and is not readable.
  """

  alias AllbertAssist.Objectives.CanonicalJSON

  @legacy_version 1
  @version 3
  @write_rule_catalog_version 2
  @replay_rule_catalog_versions [1, 2]
  @legacy_receipt_digest_domain "allbert:fanout-worker-quality-receipt:v1\0"
  @receipt_digest_domain "allbert:fanout-worker-quality-receipt:v3\0"
  @legacy_receipt_keys ~w[
    version objective_id_sha256 step_id_sha256 task_contract_sha256
    rule_catalog_version reviewer_config_sha256 provider_call_count verdict
    failed_rule_ids final_answer_sha256
  ]
  @receipt_keys ~w[
    version objective_id_sha256 step_id_sha256 task_contract_sha256
    rule_catalog_version generator_config_sha256 generation_call_count
    provider_call_count verdict final_answer_sha256
  ]
  @event_keys ~w[quality_receipt step_id step_status]
  @build_binding_keys ~w[
    objective_id step_id task_contract_sha256 rule_catalog_version
    generator_config_sha256 generation_call_count provider_call_count verdict
    final_answer
  ]
  @verify_binding_keys ~w[objective_id step_id task_contract_sha256 final_answer]

  @type receipt :: %{required(String.t()) => term()}

  @doc "Build one exact accepted v3 receipt from a single-generation worker run."
  @spec build(map()) :: {:ok, receipt()} | {:error, :invalid_quality_receipt_binding}
  def build(binding) when is_map(binding) do
    with {:ok, binding} <- normalize_map(binding),
         true <- exact_keys?(binding, @build_binding_keys),
         true <- valid_hash_inputs?(binding),
         true <- binding["rule_catalog_version"] == @write_rule_catalog_version do
      receipt = %{
        "version" => @version,
        "objective_id_sha256" => sha256(binding["objective_id"]),
        "step_id_sha256" => sha256(binding["step_id"]),
        "task_contract_sha256" => binding["task_contract_sha256"],
        "rule_catalog_version" => binding["rule_catalog_version"],
        "generator_config_sha256" => binding["generator_config_sha256"],
        "generation_call_count" => binding["generation_call_count"],
        "provider_call_count" => binding["provider_call_count"],
        "verdict" => binding["verdict"],
        "final_answer_sha256" => sha256(binding["final_answer"])
      }

      case validate_current(receipt, binding) do
        :ok -> {:ok, receipt}
        {:error, _reason} -> {:error, :invalid_quality_receipt_binding}
      end
    else
      _invalid -> {:error, :invalid_quality_receipt_binding}
    end
  end

  def build(_binding), do: {:error, :invalid_quality_receipt_binding}

  defp valid_hash_inputs?(binding) do
    Enum.all?(~w[objective_id step_id final_answer], fn key ->
      value = binding[key]
      is_binary(value) and value != ""
    end)
  end

  @doc "Validate receipt invariants and its required identity/task/answer binding."
  @spec validate(map(), map()) :: :ok | {:error, :invalid_quality_receipt}
  def validate(receipt, binding) when is_map(receipt) and is_map(binding) do
    with {:ok, receipt} <- normalize_map(receipt),
         {:ok, binding} <- normalize_map(binding),
         true <- valid_receipt?(receipt),
         true <- required_binding?(binding),
         true <- receipt["objective_id_sha256"] == sha256(binding["objective_id"]),
         true <- receipt["step_id_sha256"] == sha256(binding["step_id"]),
         true <- task_contract_digest_matches?(receipt, binding),
         true <- receipt["final_answer_sha256"] == sha256(binding["final_answer"]),
         true <- optional_bindings_match?(receipt, binding) do
      :ok
    else
      _invalid -> {:error, :invalid_quality_receipt}
    end
  end

  def validate(_receipt, _binding), do: {:error, :invalid_quality_receipt}

  @doc "Validate a receipt for a new current-catalog completion event write."
  @spec validate_current(map(), map()) :: :ok | {:error, :invalid_quality_receipt}
  def validate_current(receipt, binding) when is_map(receipt) and is_map(binding) do
    with :ok <- validate(receipt, binding),
         {:ok, receipt} <- normalize_map(receipt),
         true <- receipt["version"] == @version,
         true <- receipt["rule_catalog_version"] == @write_rule_catalog_version do
      :ok
    else
      _invalid -> {:error, :invalid_quality_receipt}
    end
  end

  def validate_current(_receipt, _binding), do: {:error, :invalid_quality_receipt}

  @doc "Validate and digest one exact receipt."
  @spec digest(map()) :: {:ok, String.t()} | {:error, :invalid_quality_receipt}
  def digest(receipt) when is_map(receipt) do
    with {:ok, receipt} <- normalize_map(receipt),
         true <- valid_receipt?(receipt) do
      domain =
        if receipt["version"] == @legacy_version,
          do: @legacy_receipt_digest_domain,
          else: @receipt_digest_domain

      {:ok, sha256(domain <> CanonicalJSON.encode(receipt))}
    else
      _invalid -> {:error, :invalid_quality_receipt}
    end
  end

  def digest(_receipt), do: {:error, :invalid_quality_receipt}

  @doc "Decode and verify the exact reviewed run_completed event payload."
  @spec from_event_payload(String.t() | map(), map()) ::
          {:ok, receipt(), String.t()} | {:error, :invalid_quality_receipt_event}
  def from_event_payload(payload, binding) do
    with {:ok, payload} <- decode_payload(payload),
         true <- exact_keys?(payload, @event_keys),
         true <- payload["step_id"] == binding_value(binding, "step_id"),
         true <- payload["step_status"] == "completed",
         receipt when is_map(receipt) <- payload["quality_receipt"],
         :ok <- validate(receipt, binding),
         {:ok, digest} <- digest(receipt) do
      {:ok, receipt, digest}
    else
      _invalid -> {:error, :invalid_quality_receipt_event}
    end
  end

  defp valid_receipt?(%{"version" => @legacy_version} = receipt) do
    exact_keys?(receipt, @legacy_receipt_keys) and
      receipt["rule_catalog_version"] in @replay_rule_catalog_versions and
      receipt["provider_call_count"] == 2 and receipt["verdict"] == "accepted" and
      receipt["failed_rule_ids"] == [] and
      Enum.all?(
        ~w[objective_id_sha256 step_id_sha256 task_contract_sha256 reviewer_config_sha256 final_answer_sha256],
        &lowercase_sha256?(receipt[&1])
      )
  end

  defp valid_receipt?(%{"version" => @version} = receipt) do
    valid_v3_shape?(receipt) and valid_v3_outcome?(receipt) and valid_v3_digests?(receipt)
  end

  defp valid_receipt?(_receipt), do: false

  defp valid_v3_shape?(receipt), do: exact_keys?(receipt, @receipt_keys)

  defp valid_v3_outcome?(receipt) do
    receipt["rule_catalog_version"] == @write_rule_catalog_version and
      receipt["generation_call_count"] == 1 and
      receipt["provider_call_count"] == receipt["generation_call_count"] and
      receipt["verdict"] == "accepted"
  end

  defp valid_v3_digests?(receipt) do
    Enum.all?(
      ~w[objective_id_sha256 step_id_sha256 task_contract_sha256 generator_config_sha256 final_answer_sha256],
      &lowercase_sha256?(receipt[&1])
    )
  end

  defp required_binding?(binding) do
    Enum.all?(@verify_binding_keys, &Map.has_key?(binding, &1)) and
      is_binary(binding["objective_id"]) and is_binary(binding["step_id"]) and
      lowercase_sha256?(binding["task_contract_sha256"]) and
      is_binary(binding["final_answer"]) and valid_versioned_task_digests?(binding)
  end

  defp task_contract_digest_matches?(receipt, binding) do
    expected =
      case Map.get(binding, "task_contract_sha256_by_rule_catalog_version") do
        digests when is_map(digests) ->
          Map.get(digests, Integer.to_string(receipt["rule_catalog_version"]))

        _missing ->
          binding["task_contract_sha256"]
      end

    receipt["task_contract_sha256"] == expected
  end

  defp valid_versioned_task_digests?(binding) do
    case Map.get(binding, "task_contract_sha256_by_rule_catalog_version") do
      nil ->
        true

      digests when is_map(digests) ->
        exact_keys?(digests, Enum.map(@replay_rule_catalog_versions, &Integer.to_string/1)) and
          Enum.all?(Map.values(digests), &lowercase_sha256?/1)

      _invalid ->
        false
    end
  end

  defp optional_bindings_match?(receipt, binding) do
    Enum.all?(
      [
        {"rule_catalog_version", "rule_catalog_version"},
        {"review_protocol_version", "review_protocol_version"},
        {"critic_group_count", "critic_group_count"},
        {"rule_group_catalog_version", "rule_group_catalog_version"},
        {"rule_group_catalog_sha256", "rule_group_catalog_sha256"},
        {"reviewer_config_sha256", "reviewer_config_sha256"},
        {"draft_call_count", "draft_call_count"},
        {"initial_critic_call_count", "initial_critic_call_count"},
        {"revision_call_count", "revision_call_count"},
        {"final_critic_call_count", "final_critic_call_count"},
        {"provider_call_count", "provider_call_count"},
        {"initial_assessment_sha256", "initial_assessment_sha256"},
        {"final_assessment_sha256", "final_assessment_sha256"},
        {"accepted_assessment_sha256", "accepted_assessment_sha256"},
        {"verdict", "verdict"},
        {"failed_rule_ids", "failed_rule_ids"}
      ],
      fn {receipt_key, binding_key} ->
        not Map.has_key?(binding, binding_key) or receipt[receipt_key] == binding[binding_key]
      end
    )
  end

  defp decode_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> normalize_map(decoded)
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp decode_payload(payload) when is_map(payload), do: normalize_map(payload)
  defp decode_payload(_payload), do: {:error, :invalid_payload}

  defp normalize_map(map) when is_map(map), do: normalize_map_entries(map)

  defp normalize_map_entries(map) do
    Enum.reduce_while(map, {:ok, %{}}, fn {key, value}, {:ok, normalized} ->
      with {:ok, key} <- normalize_key(key),
           false <- Map.has_key?(normalized, key),
           {:ok, value} <- normalize_value(value) do
        {:cont, {:ok, Map.put(normalized, key, value)}}
      else
        _invalid -> {:halt, {:error, :invalid_or_colliding_key}}
      end
    end)
  end

  defp normalize_value(value) when is_map(value), do: normalize_map_entries(value)

  defp normalize_value(value) when is_list(value) do
    value
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, normalized} ->
      case normalize_value(item) do
        {:ok, item} -> {:cont, {:ok, [item | normalized]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, normalized} -> {:ok, Enum.reverse(normalized)}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_value(value), do: {:ok, value}

  defp normalize_key(key) when is_binary(key), do: {:ok, key}
  defp normalize_key(key) when is_atom(key), do: {:ok, Atom.to_string(key)}
  defp normalize_key(_key), do: {:error, :invalid_key}

  defp binding_value(binding, key) when is_map(binding) do
    Map.get(binding, key) || Map.get(binding, safe_existing_atom(key))
  end

  defp binding_value(_binding, _key), do: nil

  defp safe_existing_atom("step_id"), do: :step_id

  defp exact_keys?(map, keys) when is_map(map), do: Enum.sort(Map.keys(map)) == Enum.sort(keys)
  defp exact_keys?(_map, _keys), do: false

  defp lowercase_sha256?(value) when is_binary(value) and byte_size(value) == 64 do
    case Base.decode16(value, case: :lower) do
      {:ok, decoded} -> byte_size(decoded) == 32
      :error -> false
    end
  end

  defp lowercase_sha256?(_value), do: false

  defp sha256(value) when is_binary(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp sha256(_value), do: nil
end
