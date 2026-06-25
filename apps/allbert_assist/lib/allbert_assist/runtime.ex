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
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.LocalSurface
  alias AllbertAssist.Coding.TurnSupervisor, as: CodingTurnSupervisor
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Runtime.MediaOutputs
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Session
  alias AllbertAssist.Signals
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
          coding_turn?: boolean(),
          coding_turn_id: nil | String.t(),
          coding_req_llm_context: nil | ReqLLM.Context.t(),
          stream_event_sink: nil | pid() | (map() -> term()),
          diagnostics: list(),
          timeout_ms: pos_integer()
        }

  @type response :: %{
          message: String.t(),
          model_payload: String.t(),
          surface_payload: String.t(),
          status: atom(),
          trace_id: nil | String.t(),
          signal_id: String.t(),
          input_signal_id: String.t(),
          user_message_id: String.t() | nil,
          assistant_message_id: String.t() | nil,
          user_id: String.t(),
          operator_id: String.t(),
          thread_id: String.t(),
          session_id: nil | String.t(),
          active_app: atom() | nil,
          actions: list(),
          decision: map() | nil,
          resource_access: list(),
          approval_handoff: map() | nil,
          media_outputs: list(),
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
         :ok <- log_runtime_turn_started(input_signal, request),
         {:ok, user_message} <- persist_user_message(request, input_signal),
         request <- put_user_message_id(request, user_message),
         request <- maybe_record_inbound_channel_refs(request, user_message),
         request <- put_thread_context(request, user_message),
         {:ok, agent_response} <- run_agent_turn(input_signal, request),
         {:ok, response_signal} <- new_response_signal(input_signal, request, agent_response),
         :ok <- log_signal(response_signal) do
      response = build_response(input_signal, response_signal, agent_response, request)

      {:ok,
       response
       |> record_trace(input_signal, response_signal, request)
       |> persist_assistant_message(request, response_signal)
       |> maybe_log_runtime_turn_completed(request)
       |> maybe_log_trace_signal(request)}
    end
  end

  def submit_user_input(_attrs), do: {:error, :invalid_request}

  defp normalize_request(attrs) do
    text =
      attrs
      |> fetch_value(:text)
      |> normalize_text()

    channel = fetch_value(attrs, :channel) || :unknown

    with {:ok, text} <- text,
         {:ok, identity} <- identity(attrs),
         {:ok, session_id} <- normalize_session_id(attrs),
         {:ok, channel_thread_ref} <- normalize_channel_thread_ref(channel, attrs),
         {:ok, thread} <- resolve_thread(attrs, identity.user_id, text, channel_thread_ref) do
      session_context = session_context(identity.user_id, session_id)
      app_context = resolve_active_app(attrs, session_context)

      {:ok,
       %{
         text: text,
         channel: channel,
         user_id: identity.user_id,
         operator_id: identity.operator_id,
         thread_id: thread.id,
         session_id: session_id,
         request_started_at: request_started_at(attrs),
         active_app: app_context.active_app,
         thread_context: empty_thread_context(identity.user_id, thread.id),
         conversation_thread: thread,
         channel_thread_ref: channel_thread_ref,
         provider_message_id: provider_message_id(attrs),
         provider_message_part_id: provider_message_part_id(attrs),
         metadata: fetch_value(attrs, :metadata) || %{},
         trace: fetch_value(attrs, :trace),
         coding_turn?: coding_turn?(attrs),
         coding_turn_id: coding_turn_id(attrs),
         coding_req_llm_context: fetch_value(attrs, :coding_req_llm_context),
         stream_event_sink: fetch_value(attrs, :stream_event_sink),
         diagnostics: session_context.diagnostics ++ app_context.diagnostics,
         timeout_ms: fetch_value(attrs, :timeout_ms) || @default_timeout_ms
       }}
    end
  end

  defp session_context(_user_id, nil), do: %{active_app: nil, diagnostics: []}

  defp session_context(user_id, session_id) do
    opts = Keyword.put(session_opts(), :touch?, true)

    case Session.get(user_id, session_id, opts) do
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

  defp resolve_active_app(attrs, session_context) do
    requested_app = fetch_value(attrs, :active_app) || fetch_value(attrs, :app_id)

    case normalize_known_app(requested_app) do
      {:ok, app_id} when not is_nil(app_id) ->
        %{active_app: app_id, diagnostics: []}

      {:ok, nil} ->
        resolve_session_or_default(session_context, [])

      {:error, :unknown_app} ->
        diagnostics = [
          %{
            source: :active_app,
            kind: :unknown_app_id,
            app_id: inspect(Redactor.redact(requested_app)),
            fallback: :allbert
          }
        ]

        resolve_session_or_default(%{active_app: nil}, diagnostics)
    end
  end

  defp resolve_session_or_default(session_context, diagnostics) do
    case normalize_known_app(session_context.active_app) do
      {:ok, app_id} when not is_nil(app_id) ->
        %{active_app: app_id, diagnostics: diagnostics}

      _other ->
        %{active_app: :allbert, diagnostics: diagnostics}
    end
  end

  defp normalize_known_app(nil), do: {:ok, nil}

  defp normalize_known_app(app_id) do
    AppRegistry.normalize_app_id(app_id)
  catch
    :exit, _reason -> if app_id == :allbert, do: {:ok, :allbert}, else: {:error, :unknown_app}
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

  defp resolve_thread(attrs, user_id, text, channel_thread_ref) do
    Conversations.resolve_thread(%{
      user_id: user_id,
      text: text,
      thread_id: fetch_value(attrs, :thread_id) || mapped_thread_id(channel_thread_ref),
      new_thread: fetch_value(attrs, :new_thread)
    })
  end

  defp mapped_thread_id(nil), do: nil

  defp mapped_thread_id(channel_thread_ref) do
    case ChannelThread.lookup_thread(channel_thread_ref) do
      {:ok, thread_id} -> thread_id
      {:error, :not_found} -> nil
      {:error, _reason} -> nil
    end
  end

  defp fetch_value(attrs, key) do
    Map.get(attrs, key) || Map.get(attrs, Atom.to_string(key))
  end

  defp normalize_channel_thread_ref(channel, attrs) do
    case channel_thread_ref_attrs(channel, attrs) do
      nil -> {:ok, nil}
      ref_attrs -> ChannelThread.normalize_ref(ref_attrs)
    end
  end

  defp channel_thread_ref_attrs(channel, attrs) do
    trust_class = fetch_value(attrs, :trust_class) || channel_trust_class(channel)

    case fetch_value(attrs, :channel_thread_ref) do
      ref_attrs when is_map(ref_attrs) ->
        ref_attrs
        |> Map.put_new(:channel, channel)
        |> Map.put_new(:trust_class, trust_class)
        |> maybe_put_ref_attr(:receiver_account_ref, fetch_value(attrs, :receiver_account_ref))

      _other ->
        provider_thread_ref = fetch_value(attrs, :provider_thread_ref)
        provider_thread_key = fetch_value(attrs, :provider_thread_key)
        receiver_account_ref = fetch_value(attrs, :receiver_account_ref)

        if provider_thread_ref || provider_thread_key || receiver_account_ref do
          %{
            channel: channel,
            receiver_account_ref: receiver_account_ref,
            provider_thread_ref: provider_thread_ref,
            provider_thread_key: provider_thread_key,
            trust_class: trust_class
          }
        end
    end
  end

  defp channel_trust_class(channel) do
    with {:ok, descriptor} <- channel_descriptor(channel) do
      Map.get(descriptor, :trust_class, :server_readable)
    else
      _error -> :server_readable
    end
  end

  defp channel_descriptor(channel) do
    case Channels.channel_descriptor(channel) do
      {:ok, descriptor} -> {:ok, descriptor}
      {:error, :unknown_channel} -> LocalSurface.descriptor(channel)
    end
  end

  defp maybe_put_ref_attr(attrs, _key, nil), do: attrs
  defp maybe_put_ref_attr(attrs, key, value), do: Map.put_new(attrs, key, value)

  defp provider_message_id(attrs) do
    fetch_value(attrs, :provider_message_id) ||
      fetch_value(attrs, :external_message_id) ||
      metadata_value(attrs, :provider_message_id) ||
      metadata_value(attrs, :external_message_id)
  end

  defp provider_message_part_id(attrs) do
    fetch_value(attrs, :provider_message_part_id) ||
      fetch_value(attrs, :part_id) ||
      metadata_value(attrs, :provider_message_part_id) ||
      metadata_value(attrs, :part_id) ||
      "0"
  end

  defp metadata_value(attrs, key) do
    case fetch_value(attrs, :metadata) do
      metadata when is_map(metadata) -> fetch_value(metadata, key)
      _metadata -> nil
    end
  end

  defp coding_turn?(attrs) do
    truthy?(fetch_value(attrs, :coding_turn?)) ||
      truthy?(fetch_value(attrs, :coding_turn)) ||
      truthy?(metadata_value(attrs, :coding_turn?)) ||
      truthy?(metadata_value(attrs, :coding_turn)) ||
      truthy?(metadata_value(attrs, :pi_mode?)) ||
      truthy?(metadata_value(attrs, :pi_mode)) ||
      metadata_value(attrs, :surface) in ["pi_mode", "coding", "tui_pi_mode"]
  end

  defp coding_turn_id(attrs) do
    fetch_value(attrs, :coding_turn_id) ||
      fetch_value(attrs, :turn_id) ||
      metadata_value(attrs, :coding_turn_id) ||
      metadata_value(attrs, :turn_id)
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp request_started_at(attrs) do
    attrs
    |> fetch_value(:request_started_at)
    |> normalize_request_started_at()
    |> case do
      nil -> DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      timestamp -> timestamp
    end
  end

  defp normalize_request_started_at(%DateTime{} = datetime) do
    datetime
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601()
  end

  defp normalize_request_started_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> normalize_request_started_at(datetime)
      _error -> nil
    end
  end

  defp normalize_request_started_at(_value), do: nil

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
        request_started_at: request.request_started_at,
        metadata: request.metadata
      }
      |> maybe_put(:active_app, request.active_app),
      source: channel_source(request.channel),
      subject: request.user_id
    )
  end

  defp new_response_signal(input_signal, request, agent_response) do
    agent_response = Response.normalize(agent_response)
    media_outputs = MediaOutputs.collect(agent_response)

    Signal.new(
      @agent_responded,
      %{
        input_signal_id: input_signal.id,
        message: agent_response.model_payload,
        model_payload: agent_response.model_payload,
        surface_payload: agent_response.surface_payload,
        status: agent_response.status,
        user_id: request.user_id,
        operator_id: request.operator_id,
        thread_id: request.thread_id,
        session_id: request.session_id,
        actions: agent_response.actions,
        decision: agent_response.decision,
        resource_access: agent_response.resource_access,
        approval_handoff: agent_response.approval_handoff,
        media_outputs: MediaOutputs.redacted(media_outputs),
        diagnostics: request.diagnostics ++ agent_response.diagnostics
      }
      |> maybe_put(:active_app, request.active_app),
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

  defp session_opts do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:session_opts, [])
  end

  @spec run_intent_agent(Signal.t(), request()) :: {:ok, map()} | {:error, term()}
  defp run_intent_agent(signal, request) do
    metadata = maybe_put(request.metadata, :stream_event_sink, request.stream_event_sink)

    IntentAgent.respond(%{
      text: request.text,
      channel: request.channel,
      user_id: request.user_id,
      operator_id: request.operator_id,
      thread_id: request.thread_id,
      session_id: request.session_id,
      active_app: request.active_app,
      thread_context: request.thread_context,
      metadata: metadata,
      coding_turn?: request.coding_turn?,
      coding_turn_id: request.coding_turn_id,
      coding_req_llm_context: request.coding_req_llm_context,
      stream_event_sink: request.stream_event_sink,
      timeout_ms: request.timeout_ms,
      input_signal_id: signal.id,
      input_signal_type: signal.type
    })
  end

  defp run_agent_turn(input_signal, %{coding_turn?: true} = request) do
    metadata = coding_turn_metadata(input_signal, request)
    request = %{request | coding_turn_id: metadata.turn_id}

    CodingTurnSupervisor.run(metadata, fn ->
      agent_runner().(input_signal, request)
    end)
  end

  defp run_agent_turn(input_signal, request), do: agent_runner().(input_signal, request)

  defp coding_turn_metadata(input_signal, request) do
    %{
      turn_id: request.coding_turn_id || "coding-turn-#{input_signal.id}",
      input_signal_id: input_signal.id,
      user_id: request.user_id,
      operator_id: request.operator_id,
      thread_id: request.thread_id,
      session_id: request.session_id,
      channel: request.channel,
      stream_event_sink: request.stream_event_sink
    }
  end

  defp build_response(input_signal, response_signal, agent_response, request) do
    agent_response = Response.normalize(agent_response)
    media_outputs = MediaOutputs.collect(agent_response)

    %{
      message: agent_response.message,
      model_payload: agent_response.model_payload,
      surface_payload: agent_response.surface_payload,
      status: agent_response.status,
      trace_id: nil,
      signal_id: response_signal.id,
      input_signal_id: input_signal.id,
      user_message_id: request.user_message_id,
      assistant_message_id: nil,
      user_id: request.user_id,
      operator_id: request.operator_id,
      thread_id: request.thread_id,
      session_id: request.session_id,
      active_app: request.active_app,
      actions: agent_response.actions,
      decision: agent_response.decision,
      resource_access: agent_response.resource_access,
      approval_handoff: agent_response.approval_handoff,
      diagnostics: request.diagnostics ++ agent_response.diagnostics
    }
    |> maybe_put(:stream_events, Map.get(agent_response, :stream_events))
    |> maybe_put(:turn_id, Map.get(agent_response, :turn_id))
    |> maybe_put(:coding_turn, Map.get(agent_response, :coding_turn))
    |> maybe_put(:coding_session_context, Map.get(agent_response, :coding_session_context))
    |> maybe_put_media_outputs(media_outputs)
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

  defp put_user_message_id(request, user_message) do
    Map.put(request, :user_message_id, user_message.id)
  end

  defp maybe_record_inbound_channel_refs(%{channel_thread_ref: nil} = request, _user_message),
    do: request

  defp maybe_record_inbound_channel_refs(request, user_message) do
    ref = Map.put(request.channel_thread_ref, :canonical_thread_id, request.thread_id)

    request
    |> record_channel_thread_link(ref)
    |> record_inbound_message_ref(ref, user_message)
  end

  defp record_channel_thread_link(request, ref) do
    case ChannelThread.link_thread(ref) do
      {:ok, _thread_ref} ->
        request

      {:error, reason} ->
        add_request_diagnostic(request, %{
          source: :channel_thread,
          operation: :link_thread,
          error: inspect(Redactor.redact(reason))
        })
    end
  end

  defp record_inbound_message_ref(%{provider_message_id: nil} = request, _ref, _user_message),
    do: request

  defp record_inbound_message_ref(request, ref, user_message) do
    attrs =
      ref
      |> Map.put(:canonical_message_id, user_message.id)
      |> Map.put(:canonical_thread_id, request.thread_id)
      |> Map.put(:provider_message_id, request.provider_message_id)
      |> Map.put(:part_id, request.provider_message_part_id)
      |> Map.put(:direction, :in)

    case ChannelThread.record_message_ref(attrs) do
      {:ok, _message_ref} ->
        request

      {:error, reason} ->
        add_request_diagnostic(request, %{
          source: :channel_thread,
          operation: :record_message_ref,
          error: inspect(Redactor.redact(reason))
        })
    end
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
          |> maybe_put_media_outputs(
            MediaOutputs.persistable(Map.get(response, :media_outputs, []))
          )

        attrs = %{
          action_log: assistant_action_log(response),
          trace_id: response.trace_id,
          response_signal_id: response_signal.id,
          metadata: metadata
        }

        case Conversations.append_assistant_message(thread, response.model_payload, attrs) do
          {:ok, message} ->
            %{response | assistant_message_id: message.id}

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
      request: trace_request(request),
      response: trace_response(response),
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

  defp trace_request(request), do: Map.drop(request, [:coding_req_llm_context])

  defp trace_response(response), do: Map.drop(response, [:coding_session_context])

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
             thread_id: request.thread_id
           }
           |> maybe_put(:active_app, request.active_app),
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

  defp log_runtime_turn_started(input_signal, request) do
    %{
      input_signal_id: input_signal.id,
      user_id: request.user_id,
      operator_id: request.operator_id,
      thread_id: request.thread_id,
      session_id: request.session_id,
      request_started_at: request.request_started_at,
      channel: request.channel
    }
    |> maybe_put(:active_app, request.active_app)
    |> Signals.runtime_turn_started()
    |> case do
      {:ok, signal} -> Signals.log(signal)
      {:error, reason} -> Logger.debug("allbert turn-start signal skipped: #{inspect(reason)}")
    end

    :ok
  end

  defp maybe_log_runtime_turn_completed(response, request) do
    %{
      input_signal_id: response.input_signal_id,
      response_signal_id: response.signal_id,
      trace_id: response.trace_id,
      status: response.status,
      user_id: request.user_id,
      operator_id: request.operator_id,
      thread_id: request.thread_id,
      session_id: request.session_id,
      channel: request.channel
    }
    |> maybe_put(:active_app, request.active_app)
    |> Signals.runtime_turn_completed()
    |> case do
      {:ok, signal} ->
        Signals.log(signal)

      {:error, reason} ->
        Logger.debug("allbert turn-completed signal skipped: #{inspect(reason)}")
    end

    response
  end

  defp add_diagnostic(response, diagnostic), do: Response.append_diagnostic(response, diagnostic)

  defp add_request_diagnostic(request, diagnostic) do
    Map.update!(request, :diagnostics, &(&1 ++ [diagnostic]))
  end

  defp normalize_session_id(attrs) do
    case fetch_value(attrs, :session_id) do
      nil -> {:ok, nil}
      session_id -> Session.normalize_session_id(session_id)
    end
  end

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

  defp maybe_put_media_outputs(map, []), do: map

  defp maybe_put_media_outputs(map, media_outputs),
    do: Map.put(map, :media_outputs, media_outputs)
end
