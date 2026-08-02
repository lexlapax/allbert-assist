defmodule AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation do
  @moduledoc """
  One-request ReqLLM adapter for grounded advisory fan-out report generation
  and its optional separate revision.

  It owns no Objective state, report selection, delivery, action, or fan-out
  authority or review verdict. The caller supplies one frozen domain snapshot,
  exact locally validated candidate bytes for revision, typed failed-rule ids,
  and exact call bounds after durable claim, budget, model-selection, and
  disclosure checks.
  """

  alias AllbertAssist.Maps
  alias AllbertAssist.Models.PromptEnvelope
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.{Report, RoleProfileConfiguration}
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Settings.ModelRuntime
  alias ReqLLM.Response

  @relationships ~w[complementary contrasting sequential supporting independent]

  @spec compose(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def compose(snapshot, profile, context)
      when is_map(snapshot) and is_map(profile) and is_map(context) do
    case compose_with_provenance(snapshot, profile, context) do
      {:ok, %{candidate: candidate}} -> {:ok, candidate}
      {:error, _reason} = error -> error
    end
  end

  def compose(_snapshot, _profile, _context), do: {:error, :invalid_composition_request}

  @doc false
  @spec compose_with_provenance(map(), map(), map()) ::
          {:ok, %{candidate: map(), configuration_sha256: String.t()}} | {:error, term()}
  def compose_with_provenance(snapshot, profile, context)
      when is_map(snapshot) and is_map(profile) and is_map(context) do
    with {:ok, model_spec} <- resolve_provider(profile, context) do
      {:ok, prompt} = prompt(snapshot)
      opts = request_opts(profile, context)
      object_schema = schema()

      with {:ok, configuration_sha256} <-
             configuration_digest(profile, object_schema, opts, :generation, []),
           {:ok, response} <-
             invoke_provider(
               req_llm_client(context),
               model_spec,
               prompt,
               object_schema,
               opts,
               context
             ),
           {:ok, candidate} <- validate_response(response) do
        {:ok, %{candidate: candidate, configuration_sha256: configuration_sha256}}
      end
    end
  end

  def compose_with_provenance(_snapshot, _profile, _context),
    do: {:error, :invalid_composition_request}

  @doc "Revise one exact locally validated candidate from closed critic-rule feedback."
  @spec revise(map(), String.t(), [String.t()], map(), map()) ::
          {:ok, map()} | {:error, term()}
  def revise(snapshot, candidate, revision_rule_ids, profile, context)
      when is_map(snapshot) and is_binary(candidate) and is_list(revision_rule_ids) and
             is_map(profile) and is_map(context) do
    case revise_with_provenance(snapshot, candidate, revision_rule_ids, profile, context) do
      {:ok, %{candidate: revised}} -> {:ok, revised}
      {:error, _reason} = error -> error
    end
  end

  def revise(_snapshot, _candidate, _revision_rule_ids, _profile, _context),
    do: {:error, :invalid_revision_request}

  @doc false
  @spec revise_with_provenance(map(), String.t(), [String.t()], map(), map()) ::
          {:ok, %{candidate: map(), configuration_sha256: String.t()}} | {:error, term()}
  def revise_with_provenance(snapshot, candidate, revision_rule_ids, profile, context)
      when is_map(snapshot) and is_binary(candidate) and is_list(revision_rule_ids) and
             is_map(profile) and is_map(context) do
    with {:ok, model_spec} <- resolve_provider(profile, context),
         {:ok, source_projection} <- Report.composition_input(snapshot),
         source_contract <- CanonicalJSON.encode(source_projection),
         :ok <- validate_canonical_candidate(candidate),
         {:ok, revision_rules} <- revision_rules(revision_rule_ids),
         {:ok, prompt} <-
           revision_prompt(source_contract, candidate, revision_rule_ids, revision_rules) do
      opts = request_opts(profile, context)
      object_schema = schema()

      with {:ok, configuration_sha256} <-
             configuration_digest(
               profile,
               object_schema,
               opts,
               :revision,
               revision_rule_ids
             ),
           {:ok, response} <-
             invoke_provider(
               req_llm_client(context),
               model_spec,
               prompt,
               object_schema,
               opts,
               context
             ),
           {:ok, revised} <- validate_response(response) do
        {:ok, %{candidate: revised, configuration_sha256: configuration_sha256}}
      end
    end
  end

  def revise_with_provenance(
        _snapshot,
        _candidate,
        _revision_rule_ids,
        _profile,
        _context
      ),
      do: {:error, :invalid_revision_request}

  defp resolve_provider(profile, context) do
    with :ok <- ensure_req_llm(context),
         {:ok, model_spec} <- ModelRuntime.model_spec(profile) do
      {:ok, model_spec}
    else
      {:error, reason} -> {:error, {:profile_unavailable, reason}}
    end
  end

  defp invoke_provider(client, model_spec, prompt, object_schema, opts, context) do
    with :ok <- ProviderAttempt.mark(context) do
      case client.generate_object(model_spec, prompt, object_schema, opts) do
        {:ok, response} -> {:ok, response}
        {:error, reason} -> {:error, {:provider_failed, reason}}
        invalid -> {:error, {:provider_failed, {:invalid_provider_result, invalid}}}
      end
    end
  rescue
    exception -> {:error, {:provider_failed, exception.__struct__}}
  catch
    :exit, reason -> {:error, {:provider_failed, {:exit, reason}}}
    kind, reason -> {:error, {:provider_failed, {kind, reason}}}
  end

  defp validate_response(response) do
    with :ok <- validate_finish_reason(response),
         object when is_map(object) <- response_object(response),
         {:ok, normalized} <- normalize_provider_object(object) do
      {:ok, normalized}
    else
      nil -> {:error, {:invalid_model_output, :empty_composition_selection}}
      {:error, reason} -> {:error, {:invalid_model_output, reason}}
      _other -> {:error, {:invalid_model_output, :invalid_composition_selection}}
    end
  end

  @doc false
  @spec prompt(map()) :: {:ok, ReqLLM.Context.t()} | {:error, term()}
  def prompt(snapshot) when is_map(snapshot) do
    with {:ok, composition_input} <- Report.composition_input(snapshot) do
      PromptEnvelope.build(
        purpose: :fanout_report_synthesis_generation,
        instruction:
          "Produce one bounded advisory synthesis candidate from this immutable fan-out snapshot. " <>
            "Follow the declared rules, but do not assess or revise the candidate. " <>
            "Allbert retains all status, receipt, authority, ordering, review, and report rendering truth.",
        rules: SynthesisPolicy.prompt_rules(),
        input: CanonicalJSON.encode(composition_input),
        input_class: :advisory_data
      )
    end
  rescue
    Jason.EncodeError -> {:error, :invalid_composition_snapshot}
  end

  def prompt(_snapshot), do: {:error, :invalid_composition_snapshot}

  defp revision_prompt(source_contract, candidate, revision_rule_ids, revision_rules) do
    PromptEnvelope.build(
      purpose: :fanout_report_synthesis_revision,
      instruction:
        "Revise the supplied candidate once to address exactly the declared failed rule ids. " <>
          "Return a replacement candidate only; do not assess it or claim that review passed. " <>
          "Allbert retains all status, receipt, authority, ordering, review, and rendering truth.",
      rules: revision_rules,
      input:
        CanonicalJSON.encode(%{
          "task_contract" => source_contract,
          "candidate" => candidate,
          "revision_rule_ids" => revision_rule_ids
        }),
      input_class: :advisory_data
    )
  end

  defp revision_rules(rule_ids) do
    rules_by_id = Map.new(SynthesisPolicy.rules(), &{&1.id, &1})

    with true <- rule_ids != [] and length(rule_ids) == MapSet.size(MapSet.new(rule_ids)),
         true <- Enum.all?(rule_ids, &Map.has_key?(rules_by_id, &1)),
         expected <- Enum.filter(SynthesisPolicy.rule_ids(), &(&1 in rule_ids)),
         true <- expected == rule_ids do
      {:ok,
       Enum.map(rule_ids, fn rule_id ->
         rule = Map.fetch!(rules_by_id, rule_id)
         {rule.prompt_id, rule.instruction}
       end)}
    else
      _invalid -> {:error, :invalid_revision_rule_ids}
    end
  end

  defp validate_canonical_candidate(candidate) do
    with {:ok, decoded} when is_map(decoded) <- Jason.decode(candidate),
         true <- exact_keys?(decoded, ~w[sections advisory_synthesis]),
         true <- CanonicalJSON.encode(decoded) == candidate do
      :ok
    else
      _invalid -> {:error, :invalid_revision_candidate}
    end
  end

  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "sections" => %{
          "type" => "array",
          "items" => section_json_schema(),
          "description" =>
            "Ordered relationship sections that partition every completed child queue_position exactly once."
        },
        "advisory_synthesis" => %{
          "type" => "string",
          "description" =>
            "One non-authoritative paragraph answering the joined request from the supplied accepted observations."
        }
      },
      "required" => ~w[sections advisory_synthesis],
      "additionalProperties" => false
    }
  end

  defp section_json_schema do
    %{
      "type" => "object",
      "properties" => %{
        "relationship" => %{"type" => "string", "enum" => @relationships},
        "ordered_queue_positions" => %{
          "type" => "array",
          "items" => %{"type" => "integer", "minimum" => 0}
        }
      },
      "required" => ~w[relationship ordered_queue_positions],
      "additionalProperties" => false
    }
  end

  defp normalize_provider_object(object) do
    with true <- exact_keys?(object, ~w[sections advisory_synthesis]) do
      {:ok,
       %{
         "sections" => field(object, "sections"),
         "advisory_synthesis" => field(object, "advisory_synthesis")
       }}
    else
      _invalid -> {:error, :invalid_synthesis_candidate}
    end
  end

  defp exact_keys?(map, expected) when is_map(map) do
    keys = Enum.map(Map.keys(map), &normalize_key/1)
    length(keys) == length(expected) and Enum.sort(keys) == Enum.sort(expected)
  end

  defp normalize_key(key) when is_binary(key), do: key
  defp normalize_key(key) when is_atom(key), do: Atom.to_string(key)
  defp normalize_key(_key), do: :invalid

  defp field(map, key) do
    case Enum.find(map, fn {raw_key, _value} -> normalize_key(raw_key) == key end) do
      {_raw_key, value} -> value
      nil -> nil
    end
  end

  defp request_opts(profile, context) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: 0.0,
      max_tokens:
        profile
        |> ModelRuntime.max_tokens(1_024)
        |> min(Map.fetch!(context, :max_output_tokens))
        |> min(1_024),
      receive_timeout:
        profile
        |> Map.get(:timeout_ms, 10_000)
        |> min(Map.fetch!(context, :timeout_ms)),
      total_timeout:
        profile
        |> Map.get(:timeout_ms, 10_000)
        |> min(Map.fetch!(context, :timeout_ms)),
      max_retries: 0,
      openai_structured_output_mode: :json_schema,
      json_repair: false
    )
    |> maybe_put_test_pid(context)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp configuration_digest(profile, object_schema, opts, phase, revision_rule_ids) do
    transport = %{
      base_url: Keyword.get(opts, :base_url),
      response_schema_sha256: sha256(CanonicalJSON.encode(object_schema)),
      temperature: Keyword.fetch!(opts, :temperature),
      max_output_tokens: Keyword.fetch!(opts, :max_tokens),
      receive_timeout_ms: Keyword.fetch!(opts, :receive_timeout),
      total_timeout_ms: Keyword.fetch!(opts, :total_timeout),
      max_retries: Keyword.fetch!(opts, :max_retries),
      structured_output_mode: Keyword.fetch!(opts, :openai_structured_output_mode),
      json_repair: Keyword.fetch!(opts, :json_repair)
    }

    with {:ok, protocol} <- SynthesisPolicy.review_protocol(),
         {:ok, catalog_sha256} <-
           SynthesisPolicy.rule_group_catalog_sha256(SynthesisPolicy.rule_group_catalog_version()) do
      extras = %{
        phase: phase,
        policy_version: SynthesisPolicy.version(),
        review_protocol_version: protocol.review_protocol_version,
        rule_group_catalog_version: SynthesisPolicy.rule_group_catalog_version(),
        rule_group_catalog_sha256: catalog_sha256
      }

      extras =
        if revision_rule_ids == [] do
          extras
        else
          Map.put(
            extras,
            :revision_rule_ids_sha256,
            sha256(CanonicalJSON.encode(revision_rule_ids))
          )
        end

      RoleProfileConfiguration.digest(:fanout_synthesis, profile, transport, extras)
    end
  end

  defp ensure_req_llm(context) do
    client = req_llm_client(context)

    if Code.ensure_loaded?(client) and function_exported?(client, :generate_object, 4) and
         Code.ensure_loaded?(ReqLLM.Response) do
      :ok
    else
      {:error, :req_llm_unavailable}
    end
  end

  defp req_llm_client(context), do: Map.get(context, :req_llm_client, ReqLLM)

  defp validate_finish_reason(response) do
    case response_finish_reason(response) do
      nil -> {:error, :missing_composition_finish_reason}
      :stop -> :ok
      "stop" -> :ok
      reason -> {:error, {:incomplete_composition_response, reason}}
    end
  end

  defp response_finish_reason(response) when is_map(response) do
    Map.get(response, :finish_reason) || Map.get(response, "finish_reason")
  end

  defp response_finish_reason(_response), do: nil

  defp response_object(response) do
    cond do
      is_map(response) and is_map(Maps.field_truthy(response, :object)) ->
        Maps.field_truthy(response, :object)

      Code.ensure_loaded?(Response) and function_exported?(Response, :object, 1) ->
        Response.object(response)

      true ->
        nil
    end
  end

  defp maybe_put_test_pid(opts, %{test_pid: pid}) when is_pid(pid),
    do: Keyword.put(opts, :test_pid, pid)

  defp maybe_put_test_pid(opts, _context), do: opts

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
