defmodule AllbertAssist.Coding.StreamingTurn do
  @moduledoc """
  ReqLLM streaming boundary for Pi-mode coding turns.

  This module owns no authority. It is called from the registered
  `direct_answer` action after the action boundary and permission decision have
  already run. Its job is to resolve the Settings Central coding model profile,
  open a provider stream, register the provider cancel callback with the
  supervised turn registry, and translate provider chunks into the v0.57 stream
  event contract.
  """

  alias AllbertAssist.Coding.Config
  alias AllbertAssist.Coding.Prompt
  alias AllbertAssist.Coding.StreamPipeline
  alias AllbertAssist.Coding.StreamEvent
  alias AllbertAssist.Coding.ToolLoop
  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime
  alias ReqLLM.Context

  @max_prompt_bytes 12_000
  @max_tool_iterations 8

  @spec answer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def answer(text, context) when is_binary(text) and is_map(context) do
    with :ok <- ensure_enabled(),
         :ok <- ensure_req_llm!(),
         {:ok, profile_name} <- model_profile_name(context),
         {:ok, profile} <- resolve_model_profile(profile_name),
         {:ok, model_spec} <- ModelRuntime.model_spec(profile),
         {:ok, tools} <- ToolLoop.tools(context),
         {:ok, prompt_input} <- prompt_input(text, context, tools),
         turn_id <- turn_id(context),
         emit_fun <- emit_fun(context, turn_id),
         loop_state <-
           initial_loop_state(text, context, profile, model_spec, tools, turn_id, emit_fun),
         {:ok, response} <- run_loop(prompt_input, loop_state, 0) do
      {:ok, response}
    else
      {:error, reason} -> {:error, reason}
    end
  rescue
    exception -> {:error, {exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, Redactor.redact(reason)}}
  end

  def answer(_text, _context), do: {:error, :invalid_streaming_turn_request}

  defp ensure_enabled do
    if streaming_enabled?(), do: :ok, else: {:error, :coding_streaming_disabled}
  end

  defp ensure_req_llm! do
    if Code.ensure_loaded?(ReqLLM) and Code.ensure_loaded?(ReqLLM.StreamResponse) and
         Code.ensure_loaded?(ReqLLM.StreamChunk) and Code.ensure_loaded?(ReqLLM.Context) do
      :ok
    else
      {:error, :req_llm_unavailable}
    end
  end

  defp prompt_input(text, context, tools) do
    prompt = Prompt.surface_bundle()
    base_context = req_llm_context(context) || Context.new([Context.system(prompt.system_prompt)])

    {:ok,
     base_context
     |> Context.append(Context.user(operator_prompt(text, context, prompt)))
     |> Map.put(:tools, tools)}
  end

  defp operator_prompt(text, context, prompt) do
    coding = coding_context(context)

    """
    Coding session:
    cwd_jail: #{field(coding, :cwd_jail) || field(coding, :workspace_root) || "unknown"}
    approval_mode: #{field(coding, :approval_mode) || "default"}
    available_tools: #{tool_names(prompt.tools)}

    Operator request:
    #{bounded_text(text)}
    """
    |> String.trim()
  end

  defp request_opts(profile, tools) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: Map.get(profile, :temperature, 0.2),
      max_tokens: ModelRuntime.max_tokens(profile, 2_000),
      receive_timeout: Map.get(profile, :timeout_ms, Config.turn_max_ms()),
      tools: tools
    )
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp initial_loop_state(text, context, profile, model_spec, tools, turn_id, emit_fun) do
    %{
      text: text,
      context: context,
      profile: profile,
      model_spec: model_spec,
      tools: tools,
      turn_id: turn_id,
      emit_fun: emit_fun,
      events: [],
      sequence: 0,
      cancel_statuses: [],
      tool_results: [],
      tool_actions: [],
      approval_handoffs: []
    }
  end

  defp run_loop(_prompt_input, %{turn_id: turn_id}, iteration)
       when iteration >= @max_tool_iterations do
    {:error, {:coding_tool_loop_limit_exceeded, turn_id, @max_tool_iterations}}
  end

  defp run_loop(prompt_input, state, iteration) do
    with {:ok, stream_response} <-
           req_llm_client().stream_text(
             state.model_spec,
             prompt_input,
             request_opts(state.profile, state.tools)
           ),
         cancel_status <- register_stream_cancel(state.turn_id, stream_response),
         {:ok, llm_response, stream_events, sequence} <-
           consume_stream_response(stream_response, state),
         state <- append_stream_result(state, stream_events, sequence, cancel_status),
         tool_calls <- actionable_tool_calls(llm_response) do
      case tool_calls do
        [] ->
          finalize_response(prompt_input, llm_response, state)

        [_ | _] ->
          with {:ok, next_context, state} <-
                 execute_tool_calls(llm_response.context || prompt_input, tool_calls, state) do
            run_loop(next_context, state, iteration + 1)
          end
      end
    end
  end

  defp consume_stream_response(stream_response, state) do
    {:ok, events_agent} = Agent.start_link(fn -> [] end)
    counter = :counters.new(1, [])
    :counters.add(counter, 1, state.sequence)

    result =
      ReqLLM.StreamResponse.process_stream(stream_response,
        on_chunk: fn chunk ->
          sequence = :counters.get(counter, 1)
          :counters.add(counter, 1, 1)

          case StreamPipeline.event_from_chunk(chunk, state.turn_id, sequence) do
            {:ok, nil} ->
              :ok

            {:ok, event} ->
              state.emit_fun.(event)
              Agent.update(events_agent, &[event | &1])

            {:error, reason} ->
              throw({:stream_event_error, reason})
          end
        end
      )

    events = Agent.get(events_agent, &Enum.reverse/1)
    sequence = :counters.get(counter, 1)
    Agent.stop(events_agent)

    case result do
      {:ok, llm_response} -> {:ok, llm_response, events, sequence}
      {:error, reason} -> {:error, reason}
    end
  end

  defp append_stream_result(state, events, sequence, cancel_status) do
    %{
      state
      | events: state.events ++ events,
        sequence: sequence,
        cancel_statuses: state.cancel_statuses ++ [cancel_status]
    }
  end

  defp execute_tool_calls(context, tool_calls, state) do
    Enum.reduce_while(tool_calls, {:ok, context, state}, fn tool_call, {:ok, context, state} ->
      with {:ok, result} <- ToolLoop.execute(tool_call, state.tools),
           {:ok, complete_event} <- tool_call_complete_event(tool_call, state),
           state <- emit_and_record_event(state, complete_event),
           result_text <- ToolLoop.result_text(result),
           {:ok, result_event} <- tool_result_event(result, result_text, state),
           state <- emit_and_record_event(state, result_event) do
        tool_message =
          Context.tool_result(
            Map.get(result, :tool_call_id),
            Map.get(result, :tool) || tool_name(tool_call),
            result_text
          )

        context = Context.append(context, tool_message)

        state = %{
          state
          | tool_results: state.tool_results ++ [tool_result_summary(result)],
            tool_actions: state.tool_actions ++ ToolLoop.action_summaries(result),
            approval_handoffs: state.approval_handoffs ++ approval_handoffs(result)
        }

        {:cont, {:ok, context, state}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp tool_call_complete_event(tool_call, state) do
    call = normalize_tool_call(tool_call)

    StreamEvent.new(:tool_call_argument_complete, %{
      turn_id: state.turn_id,
      sequence: state.sequence,
      tool_call_id: call.id,
      tool_name: call.name,
      arguments_delta: Redactor.redact(call.arguments || %{}),
      metadata: %{source: :req_llm_tool_loop}
    })
  end

  defp tool_result_event(result, result_text, state) do
    StreamEvent.new(:tool_result_delta, %{
      turn_id: state.turn_id,
      sequence: state.sequence,
      tool_call_id: Map.get(result, :tool_call_id),
      tool_name: Map.get(result, :tool),
      text: result_text,
      metadata: %{
        source: :req_llm_tool_loop,
        status: Map.get(result, :status)
      }
    })
  end

  defp emit_and_record_event(state, event) do
    state.emit_fun.(event)

    %{
      state
      | events: state.events ++ [event],
        sequence: state.sequence + 1
    }
  end

  defp finalize_response(prompt_input, llm_response, state) do
    message =
      (ReqLLM.Response.text(llm_response) || streamed_text(state.events))
      |> String.trim()

    if message == "" do
      {:error, :empty_streamed_model_text}
    else
      final_context = llm_response.context || prompt_input
      response = response_from_message(message, state, final_context)

      with {:ok, complete_event} <-
             StreamPipeline.turn_complete_event(response,
               turn_id: state.turn_id,
               sequence: state.sequence
             ) do
        state.emit_fun.(complete_event)
        {:ok, Map.put(response, :stream_events, state.events ++ [complete_event])}
      end
    end
  end

  defp response_from_message(message, state, final_context) do
    status = response_status(state)

    %{
      message: message,
      model_payload: message,
      surface_payload: message,
      status: status,
      turn_id: state.turn_id,
      actions: state.tool_actions,
      approval_handoff: List.first(state.approval_handoffs),
      coding_session_context: final_context,
      direct_answer: %{
        source: :coding_stream,
        model_profile: state.profile.name,
        provider: state.profile.provider,
        model: state.profile.model,
        prompt: %{request_bytes: byte_size(state.text)},
        diagnostic: %{
          status: :used,
          stream_cancel_registration: state.cancel_statuses,
          tool_loop_iterations: length(state.cancel_statuses),
          tool_call_count: length(state.tool_results)
        }
      },
      diagnostics: [
        %{
          source: :coding_streaming_turn,
          status: :provider_stream_connected,
          turn_id: state.turn_id,
          model_profile: state.profile.name,
          provider: state.profile.provider,
          model: state.profile.model,
          stream_cancel_registration: state.cancel_statuses,
          tool_call_count: length(state.tool_results)
        }
      ],
      coding_turn: %{
        turn_id: state.turn_id,
        status: status,
        source: :req_llm_stream_tool_loop,
        model_profile: state.profile.name,
        provider: state.profile.provider,
        model: state.profile.model,
        tool_calls: state.tool_results,
        tool_call_count: length(state.tool_results)
      }
    }
  end

  defp response_status(%{tool_results: tool_results}) do
    if Enum.any?(tool_results, &(Map.get(&1, :status) == "needs_confirmation")) do
      :needs_confirmation
    else
      :completed
    end
  end

  defp actionable_tool_calls(%ReqLLM.Response{} = response) do
    response
    |> ReqLLM.Response.tool_calls()
    |> Enum.reject(&ReqLLM.ToolCall.builtin?/1)
    |> Enum.map(&normalize_tool_call/1)
    |> Enum.reject(&(is_nil(&1.name) or &1.name == ""))
  end

  defp normalize_tool_call(%ReqLLM.ToolCall{} = call), do: ReqLLM.ToolCall.to_map(call)
  defp normalize_tool_call(%{} = call), do: ReqLLM.ToolCall.from_map(call)

  defp tool_result_summary(result) do
    %{
      id: Map.get(result, :tool_call_id),
      name: Map.get(result, :tool),
      status: Map.get(result, :status),
      ok?: Map.get(result, :ok)
    }
  end

  defp approval_handoffs(%{approval_handoff: handoff}) when is_map(handoff), do: [handoff]
  defp approval_handoffs(_result), do: []

  defp tool_name(%ReqLLM.ToolCall{} = call), do: ReqLLM.ToolCall.name(call)
  defp tool_name(%{} = call), do: Map.get(call, :name) || Map.get(call, "name")
  defp tool_name(_call), do: nil

  defp streamed_text(events) do
    events
    |> Enum.filter(&assistant_text_event?/1)
    |> Enum.map_join("", & &1.text)
  end

  defp assistant_text_event?(%{type: :assistant_token_delta, metadata: metadata}) do
    field(metadata || %{}, :kind) != :thinking
  end

  defp assistant_text_event?(%{type: :assistant_token_delta}), do: true
  defp assistant_text_event?(_event), do: false

  defp register_stream_cancel(turn_id, %ReqLLM.StreamResponse{cancel: cancel_fun})
       when is_function(cancel_fun, 0) do
    case TurnSupervisor.register_stream_cancel(turn_id, cancel_fun, source: :req_llm_stream) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp register_stream_cancel(_turn_id, _stream_response), do: :not_available

  defp emit_fun(context, turn_id) do
    case stream_event_sink(context) do
      sink when is_pid(sink) ->
        fn event ->
          send(sink, {:coding_stream_event, turn_id, event})
          :ok
        end

      sink when is_function(sink, 1) ->
        sink

      _missing ->
        fn _event -> :ok end
    end
  end

  defp model_profile_name(context) do
    value =
      field(coding_context(context), :model_profile) ||
        field(request(context), :model_profile) ||
        Config.model_profile()

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_coding_model_profile}, else: {:ok, value}

      value when is_atom(value) ->
        {:ok, Atom.to_string(value)}

      _other ->
        {:error, :missing_coding_model_profile}
    end
  end

  defp turn_id(context) do
    field(request(context), :coding_turn_id) ||
      field(request(context), :turn_id) ||
      field(context, :coding_turn_id) ||
      field(context, :turn_id) ||
      "coding-turn-#{System.unique_integer([:positive])}"
  end

  defp stream_event_sink(context) do
    metadata = field(request(context), :metadata) || %{}

    field(request(context), :stream_event_sink) ||
      field(metadata, :stream_event_sink) ||
      field(context, :stream_event_sink) ||
      registry_stream_event_sink(turn_id(context))
  end

  defp registry_stream_event_sink(turn_id) when is_binary(turn_id) do
    case TurnSupervisor.lookup(turn_id) do
      {:ok, turn} -> field(turn, :stream_event_sink)
      _error -> nil
    end
  end

  defp registry_stream_event_sink(_turn_id), do: nil

  defp coding_context(context) do
    request = request(context)
    metadata = field(request, :metadata) || %{}

    field(metadata, :coding) ||
      field(request, :coding) ||
      field(context, :coding) ||
      %{}
  end

  defp req_llm_context(context) do
    request = request(context)

    case field(request, :coding_req_llm_context) ||
           field(context, :coding_req_llm_context) ||
           field(coding_context(context), :req_llm_context) do
      %ReqLLM.Context{} = req_llm_context -> req_llm_context
      _other -> nil
    end
  end

  defp request(context), do: field(context, :request) || %{}

  defp req_llm_client do
    env()
    |> Keyword.get(:req_llm_client, ReqLLM)
  end

  defp resolve_model_profile(profile_name) do
    case Keyword.fetch(env(), :model_profile_resolver) do
      {:ok, resolver} when is_function(resolver, 1) -> resolver.(profile_name)
      :error -> Settings.resolve_model_profile(profile_name)
    end
  end

  defp streaming_enabled? do
    case Keyword.fetch(env(), :streaming_enabled?) do
      {:ok, enabled?} when is_boolean(enabled?) -> enabled?
      :error -> Config.streaming_enabled?()
    end
  end

  defp env do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
  end

  defp tool_names(tools) when is_list(tools) do
    tools
    |> Enum.map(&field(&1, :name))
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  defp tool_names(_tools), do: ""

  defp bounded_text(text) when byte_size(text) <= @max_prompt_bytes, do: text

  defp bounded_text(text) do
    binary_part(text, 0, @max_prompt_bytes) <> "...[truncated]"
  end

  defp field(map, key) when is_map(map) do
    cond do
      Map.has_key?(map, key) -> Map.get(map, key)
      Map.has_key?(map, Atom.to_string(key)) -> Map.get(map, Atom.to_string(key))
      true -> nil
    end
  end

  defp field(_map, _key), do: nil
end
