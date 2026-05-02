defmodule AllbertAssist.Runtime do
  @moduledoc """
  Signal-first boundary for submitting work to Allbert.

  Channels call `submit_user_input/1`; they do not start or call agents
  directly. The runtime turns user input into Jido signals, invokes the current
  agent runner, and returns a small response map that channel adapters can
  render.

  ## Initial signal names

  - `allbert.input.received`
  - `allbert.agent.responded`
  - `allbert.action.requested`
  - `allbert.action.completed`
  - `allbert.memory.appended`
  - `allbert.trace.recorded`
  """

  require Logger

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Agents.IntentAgent
  alias Jido.Signal

  @input_received "allbert.input.received"
  @agent_responded "allbert.agent.responded"
  @action_requested "allbert.action.requested"
  @action_completed "allbert.action.completed"
  @memory_appended "allbert.memory.appended"
  @trace_recorded "allbert.trace.recorded"

  @default_timeout_ms 120_000

  @type request :: %{
          text: String.t(),
          channel: atom() | String.t(),
          operator_id: String.t(),
          metadata: map(),
          timeout_ms: pos_integer()
        }

  @type response :: %{
          message: String.t(),
          status: atom(),
          trace_id: nil | String.t(),
          signal_id: String.t(),
          input_signal_id: String.t(),
          actions: list(),
          diagnostics: list()
        }

  @doc """
  Returns the signal names introduced for the v0.01 M2 runtime boundary.
  """
  @spec signal_types() :: %{atom() => String.t()}
  def signal_types do
    %{
      input_received: @input_received,
      agent_responded: @agent_responded,
      action_requested: @action_requested,
      action_completed: @action_completed,
      memory_appended: @memory_appended,
      trace_recorded: @trace_recorded
    }
  end

  @doc """
  Submit user input through the signal-first Allbert runtime.

  Accepts atom or string keys. Required input is `:text`; `:channel` defaults to
  `:unknown`, and `:operator_id` falls back to `:user_id` or `"local"`.
  """
  @spec submit_user_input(map()) :: {:ok, response()} | {:error, term()}
  def submit_user_input(attrs) when is_map(attrs) do
    with {:ok, request} <- normalize_request(attrs),
         {:ok, input_signal} <- new_input_signal(request),
         :ok <- log_signal(input_signal),
         {:ok, agent_response} <- agent_runner().(input_signal, request),
         {:ok, response_signal} <- new_response_signal(input_signal, request, agent_response),
         :ok <- log_signal(response_signal) do
      response = build_response(input_signal, response_signal, agent_response)

      {:ok,
       response
       |> record_trace(input_signal, response_signal, request)
       |> maybe_log_trace_signal(request)}
    end
  end

  def submit_user_input(_attrs), do: {:error, :invalid_request}

  defp normalize_request(attrs) do
    text =
      attrs
      |> fetch_value(:text)
      |> normalize_text()

    with {:ok, text} <- text do
      {:ok,
       %{
         text: text,
         channel: fetch_value(attrs, :channel) || :unknown,
         operator_id: operator_id(attrs),
         metadata: fetch_value(attrs, :metadata) || %{},
         timeout_ms: fetch_value(attrs, :timeout_ms) || @default_timeout_ms
       }}
    end
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_text}
      text -> {:ok, text}
    end
  end

  defp normalize_text(_value), do: {:error, :missing_text}

  defp operator_id(attrs) do
    attrs
    |> fetch_value(:operator_id)
    |> Kernel.||(fetch_value(attrs, :user_id))
    |> Kernel.||("local")
    |> to_string()
  end

  defp fetch_value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp new_input_signal(request) do
    Signal.new(
      @input_received,
      %{
        text: request.text,
        channel: request.channel,
        operator_id: request.operator_id,
        metadata: request.metadata
      },
      source: channel_source(request.channel),
      subject: request.operator_id
    )
  end

  defp new_response_signal(input_signal, request, agent_response) do
    Signal.new(
      @agent_responded,
      %{
        input_signal_id: input_signal.id,
        message: response_message(agent_response),
        status: response_status(agent_response),
        actions: response_actions(agent_response)
      },
      source: "/allbert/runtime",
      subject: request.operator_id
    )
  end

  defp channel_source(channel), do: "/allbert/channels/#{channel}"

  defp log_signal(%Signal{} = signal) do
    Logger.info("allbert signal #{signal.type} id=#{signal.id} source=#{signal.source}")
    :ok
  end

  defp agent_runner do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:agent_runner, &run_intent_agent/2)
  end

  @spec run_intent_agent(Signal.t(), request()) :: {:ok, map()} | {:error, term()}
  defp run_intent_agent(signal, request) do
    IntentAgent.respond(%{
      text: request.text,
      channel: request.channel,
      operator_id: request.operator_id,
      metadata: request.metadata,
      timeout_ms: request.timeout_ms,
      input_signal_id: signal.id,
      input_signal_type: signal.type
    })
  end

  defp format_agent_result(%{message: message}) when is_binary(message), do: message
  defp format_agent_result(%{content: content}) when is_binary(content), do: content
  defp format_agent_result(message) when is_binary(message), do: message
  defp format_agent_result(other), do: inspect(other, pretty: true)

  defp build_response(input_signal, response_signal, agent_response) do
    %{
      message: response_message(agent_response),
      status: response_status(agent_response),
      trace_id: nil,
      signal_id: response_signal.id,
      input_signal_id: input_signal.id,
      actions: response_actions(agent_response),
      diagnostics: []
    }
  end

  defp record_trace(response, input_signal, response_signal, request) do
    turn = %{
      input_signal: input_signal,
      response_signal: response_signal,
      request: request,
      response: response,
      agent: IntentAgent
    }

    case Runner.run("record_trace", %{turn: turn}, trace_context(input_signal, request)) do
      {:ok, %{status: :completed, trace_id: trace_id}} when is_binary(trace_id) ->
        %{response | trace_id: trace_id}

      {:ok, %{status: :completed}} ->
        response

      {:ok, trace_response} ->
        reason = trace_error(trace_response)
        Logger.warning("allbert trace write failed: #{inspect(reason)}")
        add_diagnostic(response, %{source: :trace, error: inspect(reason)})
    end
  end

  defp trace_context(input_signal, request) do
    %{
      request: %{
        operator_id: request.operator_id,
        channel: request.channel,
        input_signal_id: input_signal.id
      },
      agent: __MODULE__,
      selected_action: "record_trace",
      internal?: true
    }
  end

  defp trace_error(%{error: error}), do: error

  defp trace_error(%{actions: actions, message: message}) when is_list(actions) do
    actions
    |> Enum.find_value(&get_in(&1, [:trace_metadata, :error]))
    |> case do
      nil -> message
      error -> error
    end
  end

  defp trace_error(%{message: message}), do: message

  defp maybe_log_trace_signal(%{trace_id: nil} = response, _request), do: response

  defp maybe_log_trace_signal(%{trace_id: trace_id} = response, request) do
    case Signal.new(
           @trace_recorded,
           %{
             input_signal_id: response.input_signal_id,
             response_signal_id: response.signal_id,
             trace_id: trace_id
           },
           source: "/allbert/runtime",
           subject: request.operator_id
         ) do
      {:ok, signal} ->
        log_signal(signal)
        response

      {:error, reason} ->
        Logger.warning("allbert trace signal failed: #{inspect(reason)}")
        add_diagnostic(response, %{source: :trace_signal, error: inspect(reason)})
    end
  end

  defp add_diagnostic(response, diagnostic) do
    Map.update!(response, :diagnostics, &(&1 ++ [diagnostic]))
  end

  defp response_message(%{message: message}) when is_binary(message), do: message
  defp response_message(%{"message" => message}) when is_binary(message), do: message
  defp response_message(other), do: format_agent_result(other)

  defp response_status(%{status: status}) when is_atom(status), do: status
  defp response_status(%{"status" => status}) when is_atom(status), do: status
  defp response_status(_other), do: :completed

  defp response_actions(%{actions: actions}) when is_list(actions), do: actions
  defp response_actions(%{"actions" => actions}) when is_list(actions), do: actions
  defp response_actions(_other), do: []
end
