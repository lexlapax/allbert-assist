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
  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Channels.NotifyConsentCallback
  alias AllbertAssist.Coding.TurnSupervisor, as: CodingTurnSupervisor
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Intent.Decomposer
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Runs.Scheduler
  alias AllbertAssist.Runtime.MediaOutputs
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals
  alias Jido.Signal
  alias Jido.Signal.Bus

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
          optional(:fanout) => map(),
          optional(:fanout_start_receipt) => String.t(),
          optional(:pending_reports) => [map()],
          channel: atom() | String.t(),
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
          stream_events: list() | nil,
          turn_id: String.t() | nil,
          coding_turn: map() | nil,
          coding_session_context: ReqLLM.Context.t() | nil,
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
         {:ok, agent_response} <- run_stage_zero_or_agent(input_signal, request),
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

  @doc "Acknowledge successful kickoff delivery and make the fan-out runnable."
  @spec acknowledge_fanout_start(String.t(), map()) :: :ok | {:error, term()}
  def acknowledge_fanout_start(receipt, delivery_context) do
    with :ok <- Fanout.acknowledge_start(receipt, delivery_context),
         {:ok, parent} <- fanout_parent_for_start_receipt(receipt, delivery_context) do
      case Settings.get("objectives.fanout.confirm_before_start") do
        {:ok, true} -> :ok
        _other -> start_acknowledged_fanout(parent.id)
      end
    end
  end

  @doc "Acknowledge a pending report only after its caller-specific delivery succeeds."
  @spec acknowledge_report_delivery(String.t(), map()) ::
          :ok | {:error, :invalid_receipt | :receipt_identity_mismatch}
  def acknowledge_report_delivery(receipt, delivery_context),
    do: Fanout.acknowledge_report(receipt, delivery_context)

  @doc "Record a failed kickoff delivery so retry/status can reuse the same receipt."
  @spec delivery_failed(map(), map()) ::
          :ok | {:error, :invalid_receipt | :receipt_identity_mismatch}
  def delivery_failed(response, delivery_context \\ %{})
      when is_map(response) and is_map(delivery_context) do
    case Map.get(response, :fanout_start_receipt) do
      nil ->
        :ok

      receipt ->
        context =
          delivery_context
          |> Map.put_new(:user_id, Map.get(response, :user_id))
          |> Map.put_new(:thread_id, Map.get(response, :thread_id))
          |> Map.merge(get_in(response, [:fanout, :delivery_context]) || %{})

        Fanout.mark_start_delivery_failed(receipt, context)
    end
  end

  @doc "Run one caller delivery and durably block a fan-out kickoff if it fails."
  @spec track_delivery(map(), map(), (-> term())) :: term()
  def track_delivery(response, delivery_context, delivery_fun)
      when is_map(response) and is_map(delivery_context) and is_function(delivery_fun, 0) do
    case delivery_fun.() do
      {:error, _reason} = error ->
        _ = delivery_failed(response, delivery_context)
        error

      result ->
        result
    end
  end

  @doc "Wait for one owned fan-out to join without polling durable state."
  @spec await_fanout(String.t(), String.t(), non_neg_integer()) ::
          {:ok, Fanout.report()} | {:timeout, fanout_kickoff()} | {:error, term()}
  def await_fanout(parent_id, user_id, timeout_ms)
      when is_binary(parent_id) and is_binary(user_id) and is_integer(timeout_ms) and
             timeout_ms >= 0 do
    with {:ok, parent} <- owned_fanout(parent_id, user_id) do
      case Fanout.join_status(parent) do
        %{terminal?: true} -> {:ok, Fanout.report(parent)}
        _pending -> await_join_signal(parent, user_id, timeout_ms)
      end
    end
  end

  @doc "Subscribe a process to fan-out lifecycle signals after proving ownership."
  @spec subscribe_fanout(String.t(), String.t(), pid()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe_fanout(parent_id, user_id, sink)
      when is_binary(parent_id) and is_binary(user_id) and is_pid(sink) do
    with {:ok, _parent} <- owned_fanout(parent_id, user_id) do
      Bus.subscribe(AllbertAssist.SignalBus, "allbert.objectives.**",
        dispatch: {:pid, target: sink}
      )
    end
  end

  @doc false
  def fanout_continuation_timeout_ms do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:fanout_timeout_ms, @default_timeout_ms)
  end

  @doc "Acknowledge every fan-out handle in a response after caller delivery succeeds."
  @spec acknowledge_deliveries(map(), map()) :: :ok | {:error, term()}
  def acknowledge_deliveries(response, delivery_context \\ %{})
      when is_map(response) and is_map(delivery_context) do
    base_context =
      delivery_context
      |> Map.put_new(:user_id, Map.get(response, :user_id))
      |> Map.put_new(:thread_id, Map.get(response, :thread_id))

    start_context = Map.merge(base_context, get_in(response, [:fanout, :delivery_context]) || %{})

    with :ok <-
           acknowledge_optional_start(Map.get(response, :fanout_start_receipt), start_context),
         :ok <- Notify.mark_consent_offer_delivered(Map.get(response, :notify_offer, %{})) do
      acknowledge_pending_reports(Map.get(response, :pending_reports, []), base_context)
    end
  end

  defp acknowledge_pending_reports(pending_reports, base_context) do
    Enum.reduce_while(pending_reports, :ok, fn pending, :ok ->
      context = Map.merge(base_context, Map.get(pending, :delivery_context, %{}))

      case acknowledge_report_delivery(Map.get(pending, :report_delivery_receipt), context) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp acknowledge_optional_start(nil, _context), do: :ok

  defp acknowledge_optional_start(receipt, context),
    do: acknowledge_fanout_start(receipt, context)

  defp owned_fanout(parent_id, user_id) do
    case Objectives.get_objective(parent_id) do
      {:ok, %{fanout_role: "parent", user_id: ^user_id} = parent} -> {:ok, parent}
      {:ok, _parent} -> {:error, :fanout_identity_mismatch}
      {:error, _reason} -> {:error, :fanout_not_found}
    end
  end

  defp await_join_signal(parent, user_id, timeout_ms) do
    with {:ok, subscription_id} <- subscribe_fanout(parent.id, user_id, self()) do
      try do
        case Fanout.join_status(parent) do
          %{terminal?: true} -> {:ok, Fanout.report(parent)}
          _pending -> receive_join(parent, System.monotonic_time(:millisecond) + timeout_ms)
        end
      after
        Bus.unsubscribe(AllbertAssist.SignalBus, subscription_id)
      end
    end
  end

  defp receive_join(parent, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:signal, %Signal{type: "allbert.objectives.fanout.joined", data: data}}
      when is_map(data) ->
        if fetch_value(data, :parent_id) == parent.id do
          {:ok, Fanout.report(parent)}
        else
          receive_join(parent, deadline_ms)
        end
    after
      remaining_ms -> {:timeout, fanout_kickoff(parent)}
    end
  end

  defp fanout_kickoff(parent) do
    %{
      parent_id: parent.id,
      status: parent.status,
      delivery_state: parent.kickoff_delivery_state,
      children:
        Enum.map(Fanout.children(parent), &%{id: &1.id, title: &1.title, status: &1.status})
    }
  end

  @typep fanout_kickoff :: %{
           parent_id: String.t(),
           status: String.t(),
           delivery_state: String.t() | nil,
           children: [map()]
         }

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
    AllbertAssist.Maps.field_truthy(attrs, key)
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

  defp run_stage_zero_or_agent(input_signal, request) do
    if NotifyConsentCallback.typed_command?(request.text) do
      {:ok, request |> NotifyConsentCallback.run() |> NotifyConsentCallback.response()}
    else
      case fanout_proposal(request) do
        {:fanout, tasks} -> frame_fanout_response(request, tasks)
        {:clarify, clarification} -> {:ok, overflow_response(clarification)}
        :single -> run_agent_turn(input_signal, request)
      end
    end
  end

  defp fanout_proposal(%{coding_turn?: true}), do: :single

  defp fanout_proposal(request) do
    with {:ok, true} <- Settings.get("objectives.fanout.enabled"),
         {:ok, rollout} when rollout in ["explicit", "shadow", "automatic"] <-
           Settings.get("objectives.fanout.rollout_mode"),
         {:ok, max_children} <- Settings.get("objectives.fanout.max_children_per_fanout") do
      proposal =
        decomposer().(request.text, %{
          max_children_per_fanout: max_children,
          active_fanout?: active_fanout?(request),
          steering_turn?: steering_turn?(request),
          timeout_ms: min(request.timeout_ms, 4_000)
        })

      apply_rollout(proposal, rollout, request)
    else
      _other -> :single
    end
  end

  defp apply_rollout(_proposal, "shadow", _request), do: :single
  defp apply_rollout(proposal, "automatic", _request), do: proposal

  defp apply_rollout(proposal, "explicit", request) do
    if explicit_fanout?(request), do: proposal, else: :single
  end

  defp explicit_fanout?(request) do
    truthy?(fetch_value(request.metadata, :fanout)) or
      Regex.match?(~r/\b(in parallel|simultaneously|separately|independently)\b/iu, request.text)
  end

  defp active_fanout?(request) do
    request.user_id
    |> Objectives.list_objectives()
    |> Enum.any?(fn objective ->
      objective.fanout_role == "parent" and objective.source_thread_id == request.thread_id and
        objective.status in ~w[open running blocked]
    end)
  end

  defp steering_turn?(request) do
    active_fanout?(request) and
      Regex.match?(
        ~r/^\s*(status|progress|cancel|stop|pause|resume|retry|skip)(?:\s|$)/iu,
        request.text
      )
  end

  defp frame_fanout_response(request, tasks) do
    attrs = %{
      user_id: request.user_id,
      title: String.slice(request.text, 0, 160),
      objective: request.text,
      source_channel: to_string(request.channel),
      source_surface: source_surface(request.channel),
      source_thread_id: request.thread_id,
      session_id: request.session_id,
      active_app: optional_to_string(request.active_app),
      origin_receiver_account_ref: origin_field(request, :receiver_account_ref),
      origin_thread_ref_id: origin_field(request, :id),
      origin_thread_ref_digest: origin_ref_digest(request.channel_thread_ref)
    }

    with {:ok, framed} <- Fanout.frame(attrs, tasks) do
      {:ok, kickoff_response(framed)}
    end
  end

  defp kickoff_response(%{parent: parent, children: children, fanout_start_receipt: receipt}) do
    labels = Enum.map_join(children, "\n", &"#{&1.queue_position + 1}. #{&1.title}")

    offer? = Notify.prepare_consent_offer(parent)

    offer_text =
      if offer?,
        do: "\n\nReply `ALLBERT:NOTIFY:ON` to get reports pushed here. This offer appears once.",
        else: ""

    response =
      Response.completed(
        "I split this into #{length(children)} tasks:\n#{labels}\n\n" <>
          "Reply in this thread to steer them. I'll report when you next message; enable autonomous notifications in settings to have results pushed here." <>
          offer_text,
        fanout: %{
          parent_id: parent.id,
          children: Enum.map(children, &%{id: &1.id, title: &1.title, status: &1.status}),
          delivery_state: parent.kickoff_delivery_state,
          delivery_context: fanout_delivery_context(parent)
        },
        fanout_start_receipt: receipt
      )

    response =
      if offer? do
        Map.put(response, :notify_offer, %{
          fanout_id: parent.id,
          channel: parent.source_channel,
          user_id: parent.user_id
        })
      else
        response
      end

    maybe_add_start_confirmation(response, parent)
  end

  defp maybe_add_start_confirmation(response, parent) do
    case Settings.get("objectives.fanout.confirm_before_start") do
      {:ok, true} ->
        add_start_confirmation(response, parent)

      _other ->
        response
    end
  end

  defp add_start_confirmation(response, parent) do
    case Confirmations.create(start_confirmation_attrs(parent)) do
      {:ok, confirmation} ->
        response
        |> Map.put(:status, :needs_confirmation)
        |> Map.put(:approval_handoff, %{confirmation_id: confirmation["id"]})
        |> Map.update!(:message, &(&1 <> "\n\nApproval is required before these tasks start."))

      {:error, _reason} ->
        response
    end
  end

  defp start_confirmation_attrs(parent) do
    %{
      origin: %{actor: parent.user_id, channel: parent.source_channel},
      target_action: %{
        name: "start_fanout",
        module: inspect(AllbertAssist.Actions.Objectives.StartFanout)
      },
      target_permission: :objective_write,
      target_execution_mode: :objective_engine,
      security_decision: %{
        decision: :needs_confirmation,
        reason: "Fan-out start confirmation enabled."
      },
      params_summary: %{parent_id: parent.id, child_count: length(Fanout.children(parent))},
      resume_params_ref: %{parent_id: parent.id, user_id: parent.user_id},
      objective_id: parent.id
    }
  end

  defp start_acknowledged_fanout(parent_id) do
    case Scheduler.start_fanout(parent_id) do
      {:ok, _coordinator} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp overflow_response(%{task_count: count, max_children: max, tasks: tasks}) do
    Response.advisory(
      "I found #{count} separate tasks, but this installation allows at most #{max} per fan-out. Please narrow the list or ask me to batch it explicitly.",
      decomposition_overflow: %{task_count: count, max_children: max, tasks: tasks}
    )
  end

  defp source_surface(channel) when channel in [:web, "web"], do: "web"
  defp source_surface(_channel), do: "channel"
  defp optional_to_string(nil), do: nil
  defp optional_to_string(value), do: to_string(value)

  defp origin_field(%{channel_thread_ref: ref}, key) when is_map(ref), do: Map.get(ref, key)
  defp origin_field(_request, _key), do: nil

  defp origin_ref_digest(nil), do: nil

  defp origin_ref_digest(ref) do
    ref
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp fanout_delivery_context(parent) do
    %{
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      origin_receiver_account_ref: parent.origin_receiver_account_ref
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp decomposer do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:decomposer, &Decomposer.propose/2)
  end

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
    pending_reports = Fanout.pending_reports(request.user_id, request.thread_id)

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
      channel: request.channel,
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
    |> maybe_put(:fanout, Map.get(agent_response, :fanout))
    |> maybe_put(:fanout_start_receipt, Map.get(agent_response, :fanout_start_receipt))
    |> Map.put(:pending_reports, pending_reports)
    |> attach_pending_report_text(pending_reports)
    |> maybe_put_media_outputs(media_outputs)
  end

  defp attach_pending_report_text(response, []), do: response

  defp attach_pending_report_text(response, pending_reports) do
    text =
      pending_reports
      |> Enum.map_join("\n\n", fn pending -> format_fanout_report(pending.report) end)

    Enum.reduce([:message, :model_payload, :surface_payload], response, fn field, acc ->
      Map.update(acc, field, text, fn existing -> existing <> "\n\n" <> text end)
    end)
  end

  defp format_fanout_report(report) do
    children =
      Enum.map_join(report.children, "; ", fn child ->
        "#{report_glyph(child.status)} #{child.title}"
      end)

    "#{report.title} — #{report.join_outcome || report.status}: #{children}"
  end

  defp report_glyph("completed"), do: "✓"
  defp report_glyph("cancelled"), do: "⊘"
  defp report_glyph("failed"), do: "✗"
  defp report_glyph(_status), do: "•"

  defp fanout_parent_for_start_receipt(receipt, context) do
    user_id = fetch_value(context, :user_id)

    user_id
    |> Objectives.list_objectives()
    |> Enum.find(fn objective ->
      objective.fanout_role == "parent" and
        Fanout.receipt_for(:start, objective.id) == receipt
    end)
    |> case do
      nil -> {:error, :fanout_not_found}
      parent -> {:ok, parent}
    end
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
      {:ok, thread_ref} ->
        Map.update!(request, :channel_thread_ref, &Map.put(&1, :id, to_string(thread_ref.id)))

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
