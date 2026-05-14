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
  alias AllbertAssist.Conversations
  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.ResourceAccess
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Session
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
          user_id: String.t(),
          operator_id: String.t(),
          thread_id: String.t(),
          session_id: nil | String.t(),
          active_app: atom() | nil,
          thread_context: map(),
          metadata: map(),
          diagnostics: list(),
          timeout_ms: pos_integer()
        }

  @type response :: %{
          message: String.t(),
          status: atom(),
          trace_id: nil | String.t(),
          signal_id: String.t(),
          input_signal_id: String.t(),
          user_id: String.t(),
          operator_id: String.t(),
          thread_id: String.t(),
          session_id: nil | String.t(),
          active_app: atom() | nil,
          actions: list(),
          decision: map() | nil,
          resource_access: list(),
          approval_handoff: map() | nil,
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
  `:unknown`, and `:user_id`/`:operator_id` normalize to the same local string
  identity. When no `:thread_id` is provided, the runtime selects or creates
  the user's recent general conversation thread.
  """
  @spec submit_user_input(map()) :: {:ok, response()} | {:error, term()}
  def submit_user_input(attrs) when is_map(attrs) do
    with {:ok, request} <- normalize_request(attrs),
         {:ok, input_signal} <- new_input_signal(request),
         :ok <- log_signal(input_signal),
         {:ok, user_message} <- persist_user_message(request, input_signal),
         request <- put_thread_context(request, user_message),
         {:ok, agent_response} <- agent_runner().(input_signal, request),
         {:ok, response_signal} <- new_response_signal(input_signal, request, agent_response),
         :ok <- log_signal(response_signal) do
      response = build_response(input_signal, response_signal, agent_response, request)

      {:ok,
       response
       |> record_trace(input_signal, response_signal, request)
       |> persist_assistant_message(request, response_signal)
       |> maybe_log_trace_signal(request)}
    end
  end

  def submit_user_input(_attrs), do: {:error, :invalid_request}

  defp normalize_request(attrs) do
    text =
      attrs
      |> fetch_value(:text)
      |> normalize_text()

    with {:ok, text} <- text,
         {:ok, identity} <- identity(attrs),
         {:ok, thread} <- resolve_thread(attrs, identity.user_id, text) do
      session_id = optional_string(fetch_value(attrs, :session_id))
      session_context = session_context(identity.user_id, session_id)

      {:ok,
       %{
         text: text,
         channel: fetch_value(attrs, :channel) || :unknown,
         user_id: identity.user_id,
         operator_id: identity.operator_id,
         thread_id: thread.id,
         session_id: session_id,
         active_app: session_context.active_app,
         thread_context: empty_thread_context(identity.user_id, thread.id),
         conversation_thread: thread,
         metadata: fetch_value(attrs, :metadata) || %{},
         diagnostics: session_context.diagnostics,
         timeout_ms: fetch_value(attrs, :timeout_ms) || @default_timeout_ms
       }}
    end
  end

  defp session_context(_user_id, nil), do: %{active_app: nil, diagnostics: []}

  defp session_context(user_id, session_id) do
    case Session.get(user_id, session_id, touch?: true) do
      {:ok, entry} ->
        %{active_app: entry.active_app, diagnostics: []}

      {:error, :not_found} ->
        %{active_app: nil, diagnostics: []}

      {:error, reason} ->
        %{
          active_app: nil,
          diagnostics: [
            %{source: :session_scratchpad, error: inspect(Redactor.redact(reason))}
          ]
        }
    end
  end

  defp normalize_text(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_text}
      text -> {:ok, text}
    end
  end

  defp normalize_text(_value), do: {:error, :missing_text}

  defp identity(attrs) do
    user_id = optional_string(fetch_value(attrs, :user_id))
    operator_id = optional_string(fetch_value(attrs, :operator_id))

    cond do
      present?(user_id) and present?(operator_id) and user_id != operator_id ->
        {:error, {:identity_conflict, user_id, operator_id}}

      present?(user_id) ->
        {:ok, %{user_id: user_id, operator_id: user_id}}

      present?(operator_id) ->
        {:ok, %{user_id: operator_id, operator_id: operator_id}}

      true ->
        {:ok, %{user_id: "local", operator_id: "local"}}
    end
  end

  defp resolve_thread(attrs, user_id, text) do
    Conversations.resolve_thread(%{
      user_id: user_id,
      text: text,
      thread_id: fetch_value(attrs, :thread_id),
      new_thread: fetch_value(attrs, :new_thread)
    })
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
        user_id: request.user_id,
        operator_id: request.operator_id,
        thread_id: request.thread_id,
        session_id: request.session_id,
        active_app: request.active_app,
        metadata: request.metadata
      },
      source: channel_source(request.channel),
      subject: request.user_id
    )
  end

  defp new_response_signal(input_signal, request, agent_response) do
    Signal.new(
      @agent_responded,
      %{
        input_signal_id: input_signal.id,
        message: response_message(agent_response),
        status: response_status(agent_response),
        user_id: request.user_id,
        operator_id: request.operator_id,
        thread_id: request.thread_id,
        session_id: request.session_id,
        active_app: request.active_app,
        actions: response_actions(agent_response),
        decision: response_decision(agent_response),
        resource_access: response_resource_access(agent_response),
        approval_handoff: response_approval_handoff(agent_response),
        diagnostics: request.diagnostics ++ response_diagnostics(agent_response)
      },
      source: "/allbert/runtime",
      subject: request.user_id
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
      user_id: request.user_id,
      operator_id: request.operator_id,
      thread_id: request.thread_id,
      session_id: request.session_id,
      active_app: request.active_app,
      thread_context: request.thread_context,
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

  defp build_response(input_signal, response_signal, agent_response, request) do
    %{
      message: response_message(agent_response),
      status: response_status(agent_response),
      trace_id: nil,
      signal_id: response_signal.id,
      input_signal_id: input_signal.id,
      user_id: request.user_id,
      operator_id: request.operator_id,
      thread_id: request.thread_id,
      session_id: request.session_id,
      active_app: request.active_app,
      actions: response_actions(agent_response),
      decision: response_decision(agent_response),
      resource_access: response_resource_access(agent_response),
      approval_handoff: response_approval_handoff(agent_response),
      diagnostics: request.diagnostics ++ response_diagnostics(agent_response)
    }
  end

  defp persist_user_message(request, input_signal) do
    metadata =
      %{
        channel: request.channel,
        session_id: request.session_id
      }
      |> maybe_put(:active_app, request.active_app)

    Conversations.append_user_message(request.conversation_thread, request.text, %{
      input_signal_id: input_signal.id,
      metadata: metadata
    })
  end

  defp put_thread_context(request, user_message) do
    messages =
      Conversations.recent_context(request.conversation_thread,
        limit: 12,
        exclude_message_id: user_message.id
      )

    %{
      request
      | thread_context: %{
          thread_id: request.thread_id,
          user_id: request.user_id,
          limit: 12,
          messages: messages
        }
    }
  end

  defp empty_thread_context(user_id, thread_id) do
    %{
      thread_id: thread_id,
      user_id: user_id,
      limit: 12,
      messages: []
    }
  end

  defp persist_assistant_message(response, request, response_signal) do
    case Conversations.get_thread(request.user_id, request.thread_id) do
      {:ok, thread} ->
        metadata =
          %{
            channel: request.channel,
            session_id: request.session_id
          }
          |> maybe_put(:active_app, request.active_app)

        attrs = %{
          action_log: assistant_action_log(response),
          trace_id: response.trace_id,
          response_signal_id: response_signal.id,
          metadata: metadata
        }

        case Conversations.append_assistant_message(thread, response.message, attrs) do
          {:ok, _message} ->
            response

          {:error, reason} ->
            add_diagnostic(response, %{source: :conversation_history, error: inspect(reason)})
        end

      {:error, reason} ->
        add_diagnostic(response, %{source: :conversation_history, error: inspect(reason)})
    end
  end

  defp assistant_action_log(response) do
    %{
      status: response.status,
      actions: response.actions,
      decision: response.decision,
      resource_access: response.resource_access,
      approval_handoff: response.approval_handoff,
      diagnostics: response.diagnostics,
      input_signal_id: response.input_signal_id,
      response_signal_id: response.signal_id
    }
    |> maybe_put(:active_app, response.active_app)
    |> Redactor.redact()
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
        user_id: request.user_id,
        operator_id: request.operator_id,
        thread_id: request.thread_id,
        session_id: request.session_id,
        active_app: request.active_app,
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
             trace_id: trace_id,
             user_id: request.user_id,
             thread_id: request.thread_id,
             active_app: request.active_app
           },
           source: "/allbert/runtime",
           subject: request.user_id
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

  defp response_decision(%{decision: %Decision{} = decision}), do: Decision.to_map(decision)

  defp response_decision(%{decision: decision}) when is_map(decision),
    do: Decision.to_map(decision)

  defp response_decision(%{"decision" => decision}) when is_map(decision),
    do: Decision.to_map(decision)

  defp response_decision(_other), do: nil

  defp response_resource_access(%{resource_access: entries}) when is_list(entries),
    do: ResourceAccess.to_maps(entries)

  defp response_resource_access(%{"resource_access" => entries}) when is_list(entries),
    do: ResourceAccess.to_maps(entries)

  defp response_resource_access(%{decision: %Decision{} = decision}),
    do: ResourceAccess.to_maps(decision.resource_access)

  defp response_resource_access(%{decision: decision}) when is_map(decision) do
    decision
    |> Decision.to_map()
    |> Map.get(:resource_access, [])
    |> ResourceAccess.to_maps()
  end

  defp response_resource_access(_other), do: []

  defp response_approval_handoff(%{approval_handoff: %ApprovalHandoff{} = handoff}),
    do: ApprovalHandoff.to_map(handoff)

  defp response_approval_handoff(%{approval_handoff: handoff}) when is_map(handoff),
    do: ApprovalHandoff.to_map(handoff)

  defp response_approval_handoff(%{"approval_handoff" => handoff}) when is_map(handoff),
    do: ApprovalHandoff.to_map(handoff)

  defp response_approval_handoff(%{decision: %Decision{} = decision}),
    do: ApprovalHandoff.to_map(decision.approval_handoff)

  defp response_approval_handoff(_other), do: nil

  defp response_diagnostics(%{diagnostics: diagnostics}) when is_list(diagnostics),
    do: diagnostics

  defp response_diagnostics(%{"diagnostics" => diagnostics}) when is_list(diagnostics),
    do: diagnostics

  defp response_diagnostics(%{decision: %Decision{} = decision}), do: decision.diagnostics
  defp response_diagnostics(_other), do: []

  defp optional_string(nil), do: nil

  defp optional_string(value) do
    value
    |> to_string()
    |> String.trim()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp present?(value), do: value not in [nil, ""]

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
