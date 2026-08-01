defmodule AllbertAssist.Objectives.Fanout.PlanProvenance do
  @moduledoc """
  Closed durable codec for compact fan-out plan provenance.

  Generic redaction cannot infer that two token-named integers are structural
  accounting rather than secrets. This stateless value module validates the
  entire content-free plan schema before encoding it and is the only seam that
  may persist those counters without generic key-name redaction. It owns no
  process because canonical validation and encoding require no mutable state.
  """

  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Runtime.Redactor

  @version 1
  @required_plan_keys ~w[
    version source original_request_sha256 plan_sha256 manager_attempts budget
    deadline_unix_ms
  ]
  @optional_plan_keys ~w[manager_profile manager_profile_sha256]
  @event_only_keys ~w[child_ids child_count]
  @sources ~w[conversation_manager counted_protocol]
  @digest_pattern ~r/^[0-9a-f]{64}$/

  @type error_reason :: :invalid_fanout_plan_provenance

  @doc "Encode one already-compiled plan inside the canonical parent hint."
  @spec encode_parent_hint(map()) :: {:ok, String.t()} | {:error, error_reason()}
  def encode_parent_hint(plan) when is_map(plan) do
    with {:ok, normalized} <- normalize_plan(plan) do
      {:ok, canonical_json(%{"fanout_plan" => normalized})}
    end
  end

  def encode_parent_hint(_plan), do: {:error, :invalid_fanout_plan_provenance}

  @doc "Decode and validate the exact canonical parent hint."
  @spec decode_parent_hint(map() | String.t()) :: {:ok, map()} | {:error, error_reason()}
  def decode_parent_hint(value) do
    with {:ok, %{} = hint} <- decoded_map(value),
         true <- exact_keys?(hint, ["fanout_plan"]),
         %{} = plan <- Map.get(hint, "fanout_plan"),
         {:ok, normalized} <- normalize_plan(plan) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_fanout_plan_provenance}
    end
  end

  @doc "Encode the content-free proposal event from the same canonical plan."
  @spec encode_proposal_event(map(), [String.t()]) ::
          {:ok, String.t()} | {:error, error_reason()}
  def encode_proposal_event(plan, child_ids) when is_map(plan) and is_list(child_ids) do
    with {:ok, normalized} <- normalize_plan(plan),
         :ok <- validate_child_ids(child_ids, normalized["budget"]["child_count"]) do
      {:ok, canonical_json(event_from_plan(normalized, child_ids))}
    end
  end

  def encode_proposal_event(_plan, _child_ids),
    do: {:error, :invalid_fanout_plan_provenance}

  @doc "Decode and validate one proposal event, returning its current projection."
  @spec decode_proposal_event(map() | String.t()) ::
          {:ok, map()} | {:error, error_reason()}
  def decode_proposal_event(value) do
    with {:ok, %{} = event} <- decoded_map(value),
         {:ok, plan} <- plan_from_event(event),
         child_ids when is_list(child_ids) <- Map.get(event, "child_ids"),
         :ok <- validate_child_ids(child_ids, plan["budget"]["child_count"]),
         true <- Map.get(event, "child_count") == length(child_ids) do
      {:ok, event}
    else
      _invalid -> {:error, :invalid_fanout_plan_provenance}
    end
  end

  @doc "Verify that parent, proposal event, and durable child ordering share one plan."
  @spec verify_binding(map() | String.t(), map() | String.t(), [String.t()]) ::
          {:ok, map()} | {:error, error_reason()}
  def verify_binding(parent_hint, event_payload, child_ids) when is_list(child_ids) do
    with {:ok, parent_plan} <- decode_parent_hint(parent_hint),
         {:ok, event} <- decode_proposal_event(event_payload),
         {:ok, event_plan} <- plan_from_event(event),
         true <- event_plan == parent_plan,
         true <- event["child_ids"] == child_ids do
      {:ok, parent_plan}
    else
      _invalid -> {:error, :invalid_fanout_plan_provenance}
    end
  end

  def verify_binding(_parent_hint, _event_payload, _child_ids),
    do: {:error, :invalid_fanout_plan_provenance}

  @doc "Validate and normalize a plan map for trusted runtime consumers."
  @spec normalize_plan(map()) :: {:ok, map()} | {:error, error_reason()}
  def normalize_plan(plan) when is_map(plan) do
    plan = stringify_keys(plan)
    keys = Map.keys(plan) |> Enum.sort()
    allowed_keys = Enum.sort(@required_plan_keys)
    allowed_with_profile = Enum.sort(@required_plan_keys ++ @optional_plan_keys)
    budget = Map.get(plan, "budget")

    with true <- keys in [allowed_keys, allowed_with_profile],
         @version <- Map.get(plan, "version"),
         source when source in @sources <- Map.get(plan, "source"),
         true <- digest?(Map.get(plan, "original_request_sha256")),
         true <- digest?(Map.get(plan, "plan_sha256")),
         attempts when is_integer(attempts) and attempts >= 0 and attempts <= 2 <-
           Map.get(plan, "manager_attempts"),
         {:ok, normalized_budget} <- Budget.validate_snapshot(budget),
         true <- normalized_budget["manager_attempts"] == attempts,
         deadline when is_integer(deadline) and deadline > 0 <-
           Map.get(plan, "deadline_unix_ms"),
         true <- valid_profile_pair?(plan, keys == allowed_with_profile) do
      {:ok, Map.put(plan, "budget", normalized_budget)}
    else
      _invalid -> {:error, :invalid_fanout_plan_provenance}
    end
  end

  def normalize_plan(_plan), do: {:error, :invalid_fanout_plan_provenance}

  defp event_from_plan(plan, child_ids) do
    plan
    |> Map.drop(["version", "source"])
    |> Map.put("plan_version", plan["version"])
    |> Map.put("plan_source", plan["source"])
    |> Map.put("child_ids", child_ids)
    |> Map.put("child_count", length(child_ids))
  end

  defp plan_from_event(event) do
    keys = Map.keys(event) |> Enum.sort()
    required = Enum.sort(event_plan_keys(@required_plan_keys) ++ @event_only_keys)

    with_profile =
      Enum.sort(event_plan_keys(@required_plan_keys ++ @optional_plan_keys) ++ @event_only_keys)

    with true <- keys in [required, with_profile],
         plan <-
           event
           |> Map.drop(@event_only_keys)
           |> Map.put("version", Map.get(event, "plan_version"))
           |> Map.put("source", Map.get(event, "plan_source"))
           |> Map.drop(["plan_version", "plan_source"]),
         {:ok, normalized} <- normalize_plan(plan) do
      {:ok, normalized}
    else
      _invalid -> {:error, :invalid_fanout_plan_provenance}
    end
  end

  defp event_plan_keys(keys) do
    keys
    |> Enum.reject(&(&1 in ["version", "source"]))
    |> Kernel.++(["plan_version", "plan_source"])
  end

  defp validate_child_ids(child_ids, expected_count) do
    valid? =
      length(child_ids) == expected_count and length(Enum.uniq(child_ids)) == length(child_ids) and
        Enum.all?(child_ids, &safe_identifier?(&1, 128))

    if valid?, do: :ok, else: {:error, :invalid_fanout_plan_provenance}
  end

  defp valid_profile_pair?(_plan, false), do: true

  defp valid_profile_pair?(plan, true) do
    safe_identifier?(Map.get(plan, "manager_profile"), 120) and
      digest?(Map.get(plan, "manager_profile_sha256"))
  end

  defp safe_identifier?(value, max_bytes) when is_binary(value) do
    value != "" and value == String.trim(value) and byte_size(value) <= max_bytes and
      value == Redactor.redact(value)
  end

  defp safe_identifier?(_value, _max_bytes), do: false

  defp digest?(value) when is_binary(value), do: Regex.match?(@digest_pattern, value)
  defp digest?(_value), do: false

  defp exact_keys?(map, keys), do: Map.keys(map) |> Enum.sort() == Enum.sort(keys)

  defp decoded_map(value) when is_map(value), do: {:ok, stringify_keys(value)}

  defp decoded_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _invalid -> {:error, :invalid_fanout_plan_provenance}
    end
  end

  defp decoded_map(_value), do: {:error, :invalid_fanout_plan_provenance}

  defp stringify_keys(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {to_string(key), stringify_keys(nested)} end)

  defp stringify_keys(value) when is_list(value), do: Enum.map(value, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp canonical_json(value), do: encode_json(stringify_keys(value))

  defp encode_json(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map_join(",", fn {key, value} -> Jason.encode!(key) <> ":" <> encode_json(value) end)
    |> then(&("{" <> &1 <> "}"))
  end

  defp encode_json(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &encode_json/1) <> "]"

  defp encode_json(value), do: Jason.encode!(value)
end
