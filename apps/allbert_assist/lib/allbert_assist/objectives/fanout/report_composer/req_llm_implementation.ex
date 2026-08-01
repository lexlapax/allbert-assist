defmodule AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation do
  @moduledoc """
  One-shot ReqLLM adapter for grounded advisory fan-out report synthesis.

  It owns no Objective state, report selection, delivery, action, or fan-out
  authority. The caller supplies one frozen domain snapshot and exact call
  bounds after durable claim, budget, model-selection, and disclosure checks.
  """

  alias AllbertAssist.Maps
  alias AllbertAssist.Models.PromptEnvelope
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Settings.ModelRuntime
  alias ReqLLM.Response

  @relationships ~w[complementary contrasting sequential supporting independent]
  @section_schema {:map,
                   [
                     relationship: [
                       type: {:in, @relationships},
                       required: true,
                       doc: "Closed relationship kind for this completed-child section."
                     ],
                     ordered_queue_positions: [
                       type: {:list, :integer},
                       required: true,
                       doc: "Completed child queue positions in this section's result order."
                     ]
                   ]}
  @spec compose(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def compose(snapshot, profile, context)
      when is_map(snapshot) and is_map(profile) and is_map(context) do
    with {:ok, model_spec} <- resolve_provider(profile, context) do
      {:ok, prompt} = prompt(snapshot)
      opts = request_opts(profile, context)
      object_schema = schema()

      case invoke_provider(req_llm_client(context), model_spec, prompt, object_schema, opts) do
        {:ok, response} -> validate_response(response)
        {:error, {:provider_failed, _reason}} = error -> error
      end
    end
  end

  def compose(_snapshot, _profile, _context), do: {:error, :invalid_composition_request}

  defp resolve_provider(profile, context) do
    with :ok <- ensure_req_llm(context),
         {:ok, model_spec} <- ModelRuntime.model_spec(profile) do
      {:ok, model_spec}
    else
      {:error, reason} -> {:error, {:profile_unavailable, reason}}
    end
  end

  defp invoke_provider(client, model_spec, prompt, object_schema, opts) do
    case client.generate_object(model_spec, prompt, object_schema, opts) do
      {:ok, response} -> {:ok, response}
      {:error, reason} -> {:error, {:provider_failed, reason}}
      invalid -> {:error, {:provider_failed, {:invalid_provider_result, invalid}}}
    end
  rescue
    exception -> {:error, {:provider_failed, exception.__struct__}}
  catch
    :exit, reason -> {:error, {:provider_failed, {:exit, reason}}}
    kind, reason -> {:error, {:provider_failed, {kind, reason}}}
  end

  defp validate_response(response) do
    with :ok <- validate_finish_reason(response),
         object when is_map(object) <- response_object(response) do
      {:ok, object}
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
        purpose: :fanout_report_synthesis,
        instruction:
          "Produce one bounded advisory synthesis and its closed self-review from this immutable fan-out snapshot. Allbert retains all status, receipt, authority, ordering, and report rendering truth.",
        rules: SynthesisPolicy.prompt_rules(),
        input: CanonicalJSON.encode(composition_input),
        input_class: :advisory_data
      )
    end
  rescue
    Jason.EncodeError -> {:error, :invalid_composition_snapshot}
  end

  def prompt(_snapshot), do: {:error, :invalid_composition_snapshot}

  defp schema do
    rule_result_schema =
      {:map,
       [
         rule_id: [
           type: {:in, SynthesisPolicy.rule_ids()},
           required: true,
           doc: "One exact synthesis-contract rule id."
         ],
         verdict: [
           type: {:in, ~w[satisfied unsatisfied]},
           required: true,
           doc: "Closed verdict for this rule."
         ]
       ]}

    review_schema =
      {:map,
       [
         verdict: [
           type: {:in, ~w[accepted unresolved]},
           required: true,
           doc: "Accepted only when every catalog rule is satisfied."
         ],
         rule_results: [
           type: {:list, rule_result_schema},
           required: true,
           doc: "Every synthesis rule exactly once in catalog order."
         ],
         covered_queue_positions: [
           type: {:list, :integer},
           required: true,
           doc: "Every completed child queue position once in ascending order."
         ]
       ]}

    [
      sections: [
        type: {:list, @section_schema},
        required: true,
        doc:
          "Ordered relationship sections that partition every completed child queue_position exactly once."
      ],
      advisory_synthesis: [
        type: :string,
        required: true,
        doc:
          "One non-authoritative paragraph answering the joined request from the supplied accepted observations."
      ],
      review: [
        type: review_schema,
        required: true,
        doc: "Closed self-review and exact completed-child coverage evidence."
      ]
    ]
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
      openai_structured_output_mode: :json_schema,
      json_repair: false
    )
    |> maybe_put_test_pid(context)
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
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
end
