defmodule AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation do
  @moduledoc """
  One-request ReqLLM adapter for grounded advisory fan-out report generation.

  It owns no Objective state, report selection, delivery, action, or fan-out
  authority or review verdict. The caller supplies one frozen domain snapshot
  and exact call bounds after durable claim, budget, model-selection, and
  disclosure checks.

  v1.3 M9.b.6 removed the separate revision request with the critic topology:
  composition makes exactly one physical provider call, and the deterministic
  complete-child renderer is the only fallback.
  """

  alias AllbertAssist.Maps
  alias AllbertAssist.Models.PromptEnvelope
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Fanout.{Report, RoleProfileConfiguration}
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
             configuration_digest(profile, object_schema, opts),
           {:ok, response} <-
             invoke_provider(
               req_llm_client(context),
               model_spec,
               prompt,
               object_schema,
               opts,
               context
             ),
           {:ok, candidate} <- validate_response(response, snapshot) do
        {:ok, %{candidate: candidate, configuration_sha256: configuration_sha256}}
      end
    end
  end

  def compose_with_provenance(_snapshot, _profile, _context),
    do: {:error, :invalid_composition_request}

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

  defp validate_response(response, snapshot) do
    with :ok <- validate_finish_reason(response),
         object when is_map(object) <- response_object(response),
         {:ok, normalized} <- normalize_provider_object(object, snapshot) do
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

  # v1.3 M9.b.7: the provider is asked only for the judgment it can make. Which
  # children completed is settled fact Allbert already holds, and asking a model
  # to restate it as an array is asking it to re-derive owned data -- every
  # measured failure was exactly that re-derivation going wrong. Constrained
  # decoding cannot enforce a partition, cardinality, or the relational-section
  # rule anyway, so those invariants were only ever instructions.
  defp schema do
    %{
      "type" => "object",
      "properties" => %{
        "relationship" => %{
          "type" => "string",
          "enum" => @relationships,
          "description" =>
            "How the completed child observations stand to each other as one group. " <>
              "complementary: they cover different aspects that together give a fuller picture, and neither depends on the other. " <>
              "contrasting: they differ, disagree, or set out trade-offs against each other. " <>
              "sequential: they describe stages that follow one another in order. " <>
              "supporting: one observation provides evidence or grounding for another. " <>
              "independent: they have no substantive relationship to each other."
        },
        "advisory_synthesis" => %{
          "type" => "string",
          "description" =>
            "One non-authoritative paragraph answering the joined request from the supplied accepted observations."
        }
      },
      "required" => ~w[relationship advisory_synthesis],
      "additionalProperties" => false
    }
  end

  defp normalize_provider_object(object, snapshot) do
    with true <- exact_keys?(object, ~w[relationship advisory_synthesis]),
         relationship when relationship in @relationships <- field(object, "relationship"),
         [_first | _rest] = positions <- completed_positions(snapshot) do
      {:ok,
       %{
         "sections" => [
           %{
             "relationship" => group_relationship(relationship, positions),
             "ordered_queue_positions" => positions
           }
         ],
         "advisory_synthesis" => field(object, "advisory_synthesis")
       }}
    else
      _invalid -> {:error, :invalid_synthesis_candidate}
    end
  end

  # A lone completed child cannot stand in a relationship with anything, and
  # Report.validate_relationship_cardinality/2 already requires independent
  # there. Deriving it rather than trusting the model keeps the one structural
  # claim about the layout in deterministic code.
  defp group_relationship(_relationship, [_single]), do: "independent"
  defp group_relationship(relationship, _positions), do: relationship

  defp completed_positions(snapshot) do
    case Report.composition_input(snapshot) do
      {:ok, %{children: children}} when is_list(children) ->
        children
        |> Enum.filter(&(child_field(&1, :status) == "completed"))
        |> Enum.map(&child_field(&1, :queue_position))
        |> Enum.reject(&is_nil/1)
        |> Enum.sort()

      _unavailable ->
        []
    end
  end

  defp child_field(child, key) when is_map(child),
    do: Map.get(child, key) || Map.get(child, Atom.to_string(key))

  defp child_field(_child, _key), do: nil

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

  defp configuration_digest(profile, object_schema, opts) do
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

    extras = %{
      phase: :generation,
      policy_version: SynthesisPolicy.version()
    }

    RoleProfileConfiguration.digest(:fanout_synthesis, profile, transport, extras)
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
