defmodule AllbertAssist.Objectives.Fanout.ReportComposer.ReqLLMImplementation do
  @moduledoc """
  One-shot ReqLLM adapter for advisory fan-out report layout selection.

  It owns no Objective state, report selection, delivery, action, or fan-out
  authority. The caller supplies one frozen domain snapshot and exact call
  bounds after durable claim, budget, model-selection, and disclosure checks.
  """

  alias AllbertAssist.Maps
  alias AllbertAssist.Models.PromptEnvelope
  alias AllbertAssist.Objectives.Fanout.Report
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
  @schema [
    sections: [
      type: {:list, @section_schema},
      required: true,
      doc:
        "Ordered relationship sections that partition every completed child queue_position exactly once."
    ]
  ]
  @rules [
    typed_selection_only:
      "Return only sections and each section's two schema fields. Do not return prose, summaries, facts, claims, or additional keys.",
    exact_completed_child_partition:
      "Partition every status=completed child queue_position exactly once with no duplicate, missing, unknown, failed, cancelled, or abandoned position.",
    meaningful_relationship:
      "When two or more children completed, at least one section must relate two or more children using a non-independent relationship.",
    relationship_cardinality:
      "Use independent for exactly one child; complementary, contrasting, sequential, and supporting require at least two children.",
    layout_only:
      "Choose only closed relationship enums, grouping, and order; Allbert deterministically renders all language and all non-completed children first.",
    no_fact_or_effect_claims:
      "Do not produce result text, status text, failure text, action claims, or effect claims.",
    no_nested_fanout: "Do not propose or start more work, tools, agents, or fan-out."
  ]

  @spec compose(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def compose(snapshot, profile, context)
      when is_map(snapshot) and is_map(profile) and is_map(context) do
    with :ok <- ensure_req_llm(context),
         {:ok, model_spec} <- ModelRuntime.model_spec(profile),
         {:ok, prompt} <- prompt(snapshot),
         {:ok, response} <-
           req_llm_client(context).generate_object(
             model_spec,
             prompt,
             @schema,
             request_opts(profile, context)
           ),
         :ok <- validate_finish_reason(response),
         object when is_map(object) <- response_object(response) do
      {:ok, object}
    else
      nil -> {:error, :empty_composition_selection}
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_composition_selection}
    end
  rescue
    exception -> {:error, exception.__struct__}
  catch
    :exit, reason -> {:error, reason}
    kind, reason -> {:error, {kind, reason}}
  end

  def compose(_snapshot, _profile, _context), do: {:error, :invalid_composition_request}

  @doc false
  @spec prompt(map()) :: {:ok, ReqLLM.Context.t()} | {:error, term()}
  def prompt(snapshot) when is_map(snapshot) do
    with {:ok, composition_input} <- Report.composition_input(snapshot) do
      PromptEnvelope.build(
        purpose: :fanout_report_composition,
        instruction:
          "Select how Allbert should deterministically present this immutable fan-out result snapshot. Allbert, not the model, writes the report.",
        rules: @rules,
        input: Jason.encode!(composition_input),
        input_class: :advisory_data
      )
    end
  rescue
    Jason.EncodeError -> {:error, :invalid_composition_snapshot}
  end

  def prompt(_snapshot), do: {:error, :invalid_composition_snapshot}

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
      nil -> :ok
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
