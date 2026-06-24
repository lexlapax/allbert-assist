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
  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime
  alias ReqLLM.Context

  @max_prompt_bytes 12_000

  @spec answer(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def answer(text, context) when is_binary(text) and is_map(context) do
    with :ok <- ensure_enabled(),
         :ok <- ensure_req_llm!(),
         {:ok, profile_name} <- model_profile_name(context),
         {:ok, profile} <- resolve_model_profile(profile_name),
         {:ok, model_spec} <- ModelRuntime.model_spec(profile),
         {:ok, prompt_input} <- prompt_input(text, context),
         {:ok, stream_response} <-
           req_llm_client().stream_text(model_spec, prompt_input, request_opts(profile)),
         turn_id <- turn_id(context),
         cancel_status <- register_stream_cancel(turn_id, stream_response),
         emit_fun <- emit_fun(context, turn_id),
         {:ok, events} <-
           StreamPipeline.emit_stream_response(stream_response, [turn_id: turn_id], emit_fun),
         {:ok, response} <- response_from_events(text, profile, events, context, cancel_status),
         {:ok, complete_event} <-
           StreamPipeline.turn_complete_event(response,
             turn_id: turn_id,
             sequence: length(events)
           ) do
      emit_fun.(complete_event)
      {:ok, Map.put(response, :stream_events, events ++ [complete_event])}
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

  defp prompt_input(text, context) do
    prompt = Prompt.surface_bundle()

    {:ok,
     Context.new([
       Context.system(prompt.system_prompt),
       Context.user(operator_prompt(text, context, prompt))
     ])}
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

  defp request_opts(profile) do
    profile
    |> ModelRuntime.request_opts()
    |> Keyword.merge(
      temperature: Map.get(profile, :temperature, 0.2),
      max_tokens: ModelRuntime.max_tokens(profile, 2_000),
      receive_timeout: Map.get(profile, :timeout_ms, Config.turn_max_ms())
    )
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp response_from_events(text, profile, events, context, cancel_status) do
    message =
      events
      |> Enum.filter(&assistant_text_event?/1)
      |> Enum.map_join("", & &1.text)
      |> String.trim()

    if message == "" do
      {:error, :empty_streamed_model_text}
    else
      turn_id = turn_id(context)

      {:ok,
       %{
         message: message,
         model_payload: message,
         surface_payload: message,
         status: :completed,
         turn_id: turn_id,
         direct_answer: %{
           source: :coding_stream,
           model_profile: profile.name,
           provider: profile.provider,
           model: profile.model,
           prompt: %{request_bytes: byte_size(text)},
           diagnostic: %{status: :used, stream_cancel_registration: cancel_status}
         },
         diagnostics: [
           %{
             source: :coding_streaming_turn,
             status: :provider_stream_connected,
             turn_id: turn_id,
             model_profile: profile.name,
             provider: profile.provider,
             model: profile.model,
             stream_cancel_registration: cancel_status
           }
         ],
         coding_turn: %{
           turn_id: turn_id,
           status: :completed,
           source: :req_llm_stream,
           model_profile: profile.name,
           provider: profile.provider,
           model: profile.model
         }
       }}
    end
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
