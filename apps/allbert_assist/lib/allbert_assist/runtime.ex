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
  alias AllbertAssist.FirstRun.Disclosure
  alias AllbertAssist.Intent.Decomposer
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Intent.Steering
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget, as: FanoutBudget
  alias AllbertAssist.Objectives.Runs.Scheduler
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Runtime.DeliveryAcknowledgement
  alias AllbertAssist.Runtime.FanoutDiagnostics
  alias AllbertAssist.Runtime.MediaOutputs
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Runtime.Response
  alias AllbertAssist.Search.Surface, as: SearchSurface
  alias AllbertAssist.Session
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelReadiness
  alias AllbertAssist.Signals
  alias Jido.Signal
  alias Jido.Signal.Bus

  @input_received "allbert.input.received"
  @agent_responded "allbert.agent.responded"
  @action_requested "allbert.action.requested"
  @action_completed "allbert.action.completed"
  @persist_attached_fanout_report "persist_attached_fanout_report"
  @memory_appended "allbert.memory.appended"
  @trace_recorded "allbert.trace.recorded"

  @default_timeout_ms 120_000
  @fanout_execution_roles [:direct_answer, :fanout_synthesis]

  @type request :: %{
          text: String.t(),
          operator_text: String.t() | nil,
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
          allbert_pack_epoch: EffectGuard.epoch(),
          diagnostics: list(),
          timeout_ms: pos_integer()
        }

  @type response :: %{
          optional(:fanout) => map(),
          optional(:fanout_start_receipt) => String.t(),
          optional(:decomposition_overflow) => map(),
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
    with {:ok, epoch} <- EffectGuard.admit_ready() do
      submit_user_input(attrs, allbert_pack_epoch: epoch)
    end
  end

  def submit_user_input(_attrs), do: {:error, :invalid_request}

  @doc "Submit through the first-party carried Pack-epoch path."
  @spec submit_user_input(map(), keyword()) :: {:ok, response()} | {:error, term()}
  def submit_user_input(attrs, allbert_pack_epoch: epoch) when is_map(attrs) do
    with :ok <- EffectGuard.validate(epoch) do
      do_submit_user_input(attrs, %{allbert_pack_epoch: epoch})
    end
  end

  def submit_user_input(_attrs, _opts), do: {:error, :invalid_options}

  defp do_submit_user_input(attrs, effect_context) do
    with {:ok, request} <- normalize_request(attrs, effect_context),
         {:ok, input_signal} <- new_input_signal(request),
         :ok <- log_signal(input_signal),
         :ok <- log_runtime_turn_started(input_signal, request),
         {:ok, admission} <- persist_user_message(request, input_signal),
         user_message <- admission.message,
         request <- put_inbound_admission(request, admission),
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

  @doc "Return bounded operator wording for persistence failures that must not expose internals."
  @spec operator_error_message(term()) :: String.t() | nil
  def operator_error_message({:inbound_admission_failed, _kind}),
    do: "Allbert could not save that request. Nothing was started; retry it."

  def operator_error_message(_reason), do: nil

  @doc "Acknowledge successful kickoff delivery and make the fan-out runnable."
  @spec acknowledge_fanout_start(String.t(), map()) :: :ok | {:error, term()}
  def acknowledge_fanout_start(receipt, delivery_context) do
    with :ok <- validate_delivery_epoch(delivery_context),
         {:ok, parent} <-
           DeliveryAcknowledgement.run(fn ->
             acknowledge_start_receipt(receipt, delivery_context)
           end) do
      case Settings.get("objectives.fanout.confirm_before_start") do
        {:ok, true} -> :ok
        _other -> start_acknowledged_fanout(parent)
      end
    end
  end

  @doc "Acknowledge a pending report only after its caller-specific delivery succeeds."
  @spec acknowledge_report_delivery(String.t(), map()) :: :ok | {:error, term()}
  def acknowledge_report_delivery(receipt, delivery_context) do
    with :ok <- validate_delivery_epoch(delivery_context) do
      DeliveryAcknowledgement.run(fn ->
        Fanout.acknowledge_report(receipt, delivery_context)
      end)
    end
  end

  @doc "Record a failed kickoff delivery so retry/status can reuse the same receipt."
  @spec delivery_failed(map(), map()) :: :ok | {:error, term()}
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

        with :ok <- validate_delivery_epoch(context) do
          DeliveryAcknowledgement.run(fn ->
            Fanout.mark_start_delivery_failed(receipt, context)
          end)
        end
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
      case Fanout.parent_projection(parent) do
        %{phase: :joined, authoritatively_joined?: true} ->
          {:ok, Fanout.report(parent)}

        %{phase: :recovering} ->
          _ = Fanout.wake_recovery(parent)
          await_join_signal(parent, user_id, timeout_ms)

        _pending ->
          await_join_signal(parent, user_id, timeout_ms)
      end
    end
  end

  @doc "Subscribe a process to fan-out lifecycle signals after proving ownership."
  @spec subscribe_fanout(String.t(), String.t(), pid()) ::
          {:ok, String.t()} | {:error, term()}
  def subscribe_fanout(parent_id, user_id, sink)
      when is_binary(parent_id) and is_binary(user_id) and is_pid(sink) do
    with {:ok, _parent} <- owned_fanout(parent_id, user_id) do
      Bus.subscribe(fanout_bus(), "allbert.objectives.**", dispatch: {:pid, target: sink})
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

    with :ok <- acknowledge_kickoff_delivery(response, delivery_context),
         :ok <- validate_delivery_epoch(base_context),
         :ok <-
           Notify.mark_consent_offer_delivered(
             Map.get(response, :notify_offer, %{}),
             base_context
           ) do
      acknowledge_pending_reports(Map.get(response, :pending_reports, []), base_context)
    end
  end

  @doc "Acknowledge only the kickoff handle after its caller-specific delivery succeeds."
  @spec acknowledge_kickoff_delivery(map(), map()) :: :ok | {:error, term()}
  def acknowledge_kickoff_delivery(response, delivery_context \\ %{})
      when is_map(response) and is_map(delivery_context) do
    base_context =
      delivery_context
      |> Map.put_new(:user_id, Map.get(response, :user_id))
      |> Map.put_new(:thread_id, Map.get(response, :thread_id))

    start_context = Map.merge(base_context, get_in(response, [:fanout, :delivery_context]) || %{})
    acknowledge_optional_start(Map.get(response, :fanout_start_receipt), start_context)
  end

  @doc "Closed caller capability required before the runtime may frame fan-out work."
  @spec fanout_delivery_ack_capability() :: String.t()
  def fanout_delivery_ack_capability, do: "fanout_delivery_ack_v1"

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

  defp acknowledge_start_receipt(receipt, delivery_context) do
    with :ok <- Fanout.acknowledge_start(receipt, delivery_context) do
      Fanout.parent_for_start_receipt(receipt, delivery_context)
    end
  end

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
        case Fanout.parent_projection(parent) do
          %{phase: :joined, authoritatively_joined?: true} ->
            {:ok, Fanout.report(parent)}

          %{phase: :recovering} ->
            _ = Fanout.wake_recovery(parent)
            receive_join(parent, System.monotonic_time(:millisecond) + timeout_ms)

          _pending ->
            receive_join(parent, System.monotonic_time(:millisecond) + timeout_ms)
        end
      after
        Bus.unsubscribe(fanout_bus(), subscription_id)
      end
    end
  end

  defp receive_join(parent, deadline_ms) do
    remaining_ms = max(deadline_ms - System.monotonic_time(:millisecond), 0)

    receive do
      {:signal, %Signal{type: "allbert.objectives.fanout.joined", data: data}}
      when is_map(data) ->
        if fetch_value(data, :parent_id) == parent.id do
          case Fanout.parent_projection(parent) do
            %{phase: :joined, authoritatively_joined?: true} ->
              {:ok, Fanout.report(parent)}

            %{phase: :recovering} ->
              _ = Fanout.wake_recovery(parent)
              receive_join(parent, deadline_ms)

            _not_joined ->
              receive_join(parent, deadline_ms)
          end
        else
          receive_join(parent, deadline_ms)
        end
    after
      remaining_ms -> receive_join_timeout(parent)
    end
  end

  # Signals are a low-latency wake-up only. The durable projection gets the
  # final word at the timeout boundary so a committed report cannot be hidden
  # by a failed or delayed publication.
  defp receive_join_timeout(parent) do
    case Fanout.parent_projection(parent) do
      %{phase: :joined, authoritatively_joined?: true} ->
        {:ok, Fanout.report(parent)}

      %{phase: :recovering} ->
        _ = Fanout.wake_recovery(parent)
        {:timeout, fanout_kickoff(parent)}

      _pending ->
        {:timeout, fanout_kickoff(parent)}
    end
  end

  defp fanout_bus do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:fanout_bus, AllbertAssist.SignalBus)
  end

  defp fanout_kickoff(parent) do
    projection = Fanout.parent_projection(parent)

    if projection.phase == :recovering do
      _ = Fanout.wake_recovery(parent)
    end

    %{
      parent_id: parent.id,
      status: projection.display_status,
      fanout_phase: projection.phase,
      delivery_state: parent.kickoff_delivery_state,
      children:
        Enum.map(
          projection.children,
          &%{id: &1.id, title: &1.title, status: &1.status}
        )
    }
  end

  @typep fanout_kickoff :: %{
           parent_id: String.t(),
           status: String.t(),
           fanout_phase: atom(),
           delivery_state: String.t() | nil,
           children: [map()]
         }

  defp normalize_request(attrs, effect_context) do
    text =
      attrs
      |> fetch_value(:text)
      |> normalize_text()

    channel = fetch_value(attrs, :channel) || :unknown

    with {:ok, text} <- text,
         {:ok, operator_text} <- normalize_operator_text(attrs, text),
         {:ok, identity} <- identity(attrs),
         {:ok, session_id} <- normalize_session_id(attrs),
         {:ok, channel_thread_ref} <- normalize_channel_thread_ref(channel, attrs),
         {:ok, thread} <- resolve_thread(attrs, identity.user_id, text, channel_thread_ref) do
      session_context = session_context(identity.user_id, session_id)
      app_context = resolve_active_app(attrs, session_context)

      {:ok,
       %{
         text: text,
         operator_text: operator_text,
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
         external_user_id: fetch_value(attrs, :external_user_id),
         metadata: fetch_value(attrs, :metadata) || %{},
         trace: fetch_value(attrs, :trace),
         coding_turn?: coding_turn?(attrs),
         coding_turn_id: coding_turn_id(attrs),
         coding_req_llm_context: fetch_value(attrs, :coding_req_llm_context),
         stream_event_sink: fetch_value(attrs, :stream_event_sink),
         allbert_pack_epoch: effect_context.allbert_pack_epoch,
         delivery_ack_capability: fetch_value(attrs, :delivery_ack_capability),
         fanout_manager_mode: :off,
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

  defp normalize_operator_text(attrs, default_text) do
    cond do
      Map.has_key?(attrs, :operator_text) ->
        normalize_operator_text_value(Map.get(attrs, :operator_text))

      Map.has_key?(attrs, "operator_text") ->
        normalize_operator_text_value(Map.get(attrs, "operator_text"))

      true ->
        {:ok, default_text}
    end
  end

  defp normalize_operator_text_value(nil), do: {:ok, nil}

  defp normalize_operator_text_value(value) when is_binary(value) do
    case String.trim(value) do
      "" -> {:error, :empty_operator_text}
      text -> {:ok, text}
    end
  end

  defp normalize_operator_text_value(_value), do: {:error, :invalid_operator_text}

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

    conversation_scope =
      fetch_value(attrs, :conversation_scope) || metadata_value(attrs, :conversation_scope) ||
        :unknown

    case fetch_value(attrs, :channel_thread_ref) do
      ref_attrs when is_map(ref_attrs) ->
        ref_attrs
        |> Map.put_new(:channel, channel)
        |> Map.put_new(:trust_class, trust_class)
        |> Map.put_new(:conversation_scope, conversation_scope)
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
            trust_class: trust_class,
            conversation_scope: conversation_scope
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

    IntentAgent.respond(
      %{
        text: request.text,
        operator_text: request.operator_text,
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
        fanout_manager_mode: request.fanout_manager_mode,
        timeout_ms: request.timeout_ms,
        input_signal_id: signal.id,
        input_signal_type: signal.type
      },
      effect_epoch_opts(request)
    )
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
    case Steering.handle(request) do
      {:ok, response} ->
        {:ok, response}

      :not_steering ->
        run_non_steering_stage_zero(input_signal, request)
    end
  end

  defp run_non_steering_stage_zero(input_signal, request) do
    cond do
      SearchSurface.command?(request.text) ->
        SearchSurface.dispatch_text(request.text, search_surface_context(request))

      NotifyConsentCallback.typed_command?(request.text) ->
        {:ok, request |> NotifyConsentCallback.run() |> NotifyConsentCallback.response()}

      true ->
        run_fanout_or_agent(input_signal, request)
    end
  end

  defp search_surface_context(request) do
    ref = request.channel_thread_ref || %{}

    %{
      user_id: request.user_id,
      operator_id: request.operator_id,
      channel: request.channel,
      surface: request.channel,
      thread_id: request.thread_id,
      source_message_id: request.user_message_id,
      channel_thread_ref: ref,
      trust_class: Map.get(ref, :trust_class),
      conversation_scope: Map.get(ref, :conversation_scope),
      origin:
        Map.take(ref, [
          :owner_scope,
          :channel,
          :receiver_account_ref,
          :provider_thread_key
        ])
    }
  end

  defp run_fanout_or_agent(input_signal, request) do
    case fanout_proposal(request) do
      {:fanout, %FanoutPlan{} = plan} ->
        frame_fanout_or_fallback(input_signal, request, plan, nil)

      {:clarify, clarification} ->
        {:ok, overflow_response(clarification)}

      {:agent, mode} ->
        run_managed_agent_turn(input_signal, request, mode)

      :single ->
        run_agent_turn(input_signal, request)
    end
  end

  defp fanout_proposal(%{coding_turn?: true}), do: :single

  defp fanout_proposal(%{delivery_ack_capability: capability})
       when capability != "fanout_delivery_ack_v1",
       do: :single

  defp fanout_proposal(request) do
    if fanout_eligible_turn?(request),
      do: fanout_proposal_for_eligible_turn(request),
      else: :single
  end

  defp fanout_proposal_for_eligible_turn(request) do
    with {:ok, true} <- Settings.get("objectives.fanout.enabled"),
         {:ok, rollout} when rollout in ["explicit", "shadow", "automatic"] <-
           Settings.get("objectives.fanout.rollout_mode"),
         {:ok, max_children} <- Settings.get("objectives.fanout.max_children_per_fanout") do
      proposal =
        decomposer().(request.operator_text, %{
          max_children_per_fanout: max_children,
          active_fanout?: active_fanout?(request),
          steering_turn?: steering_turn?(request),
          timeout_ms: min(request.timeout_ms, 4_000)
        })

      apply_rollout(proposal, rollout, request, max_children)
    else
      _other -> :single
    end
  end

  defp apply_rollout({:fanout, tasks}, rollout, request, max_children) do
    if rollout == "shadow" or (rollout == "explicit" and not explicit_fanout?(request)) do
      {:agent, if(rollout == "shadow", do: :off, else: manager_mode(rollout, request))}
    else
      case FanoutPlan.compile_counted(request.operator_text, tasks, max_children: max_children) do
        {:ok, plan} -> {:fanout, plan}
        {:error, _reason} -> :single
      end
    end
  end

  defp apply_rollout({:clarify, _clarification} = proposal, "automatic", _request, _max),
    do: proposal

  defp apply_rollout({:clarify, _clarification} = proposal, "explicit", request, _max) do
    if explicit_fanout?(request), do: proposal, else: {:agent, :off}
  end

  defp apply_rollout({:clarify, _clarification}, "shadow", _request, _max),
    do: {:agent, :off}

  defp apply_rollout({:invalid_counted, _reason}, _rollout, _request, _max), do: :single

  defp apply_rollout(:single, rollout, request, _max),
    do: {:agent, manager_mode(rollout, request)}

  defp manager_mode("automatic", _request), do: :automatic
  defp manager_mode("shadow", _request), do: :shadow

  defp manager_mode("explicit", request) do
    if explicit_fanout?(request), do: :automatic, else: :off
  end

  defp fanout_eligible_turn?(request) do
    case request.operator_text do
      text when is_binary(text) ->
        text = String.trim(text)
        text != "" and not String.starts_with?(text, "/") and not active_fanout?(request)

      nil ->
        false
    end
  end

  defp run_managed_agent_turn(input_signal, request, mode) do
    request = %{request | fanout_manager_mode: mode}

    case run_agent_turn(input_signal, request) do
      {:ok, %{parallel_work_plan: %FanoutPlan{} = plan} = response} when mode == :automatic ->
        case revalidate_manager_plan(plan, request) do
          {:ok, validated_plan} ->
            frame_fanout_or_fallback(input_signal, request, validated_plan, response)

          {:error, reason} ->
            {:ok,
             response
             |> strip_fanout_control()
             |> add_admission_diagnostic(:rejected, revalidation_failure_kind(reason))}
        end

      {:ok, %{parallel_work_clarification: clarification} = response}
      when mode == :automatic ->
        {:ok,
         clarification
         |> overflow_response()
         |> copy_manager_fact(response)}

      {:ok, response} when is_map(response) and mode == :shadow ->
        {:ok,
         response
         |> strip_fanout_control()
         |> add_admission_diagnostic(:shadow_only)}

      {:ok, response} when is_map(response) ->
        {:ok, strip_fanout_control(response)}

      other ->
        other
    end
  end

  defp revalidate_manager_plan(%FanoutPlan{} = plan, request) do
    max_children =
      case Settings.get("objectives.fanout.max_children_per_fanout") do
        {:ok, value} when is_integer(value) -> value
        _other -> 8
      end

    expected_digest =
      :crypto.hash(:sha256, request.operator_text) |> Base.encode16(case: :lower)

    with true <- plan.original_request == request.operator_text,
         true <- plan.original_request_sha256 == expected_digest do
      FanoutPlan.compile(request.operator_text, plan.children,
        source: :model,
        max_children: max_children
      )
    else
      false -> {:error, :plan_request_binding_mismatch}
    end
  end

  defp explicit_fanout?(request) do
    truthy?(fetch_value(request.metadata, :fanout)) or
      Regex.match?(
        ~r/\b(in parallel|simultaneously|separately|independently)\b/iu,
        request.operator_text
      )
  end

  defp active_fanout?(request) do
    match?({:ok, _parent}, Fanout.active_parent(request.user_id, request.thread_id))
  end

  defp steering_turn?(request) do
    active_fanout?(request) and
      Regex.match?(
        ~r/^\s*(status|progress|cancel|stop|pause|resume|retry|skip)(?:\s|$)/iu,
        request.operator_text
      )
  end

  defp frame_fanout_or_fallback(input_signal, request, plan, fallback_response) do
    case frame_fanout_response(request, plan, fallback_response) do
      {:ok, _response} = success ->
        success

      {:error, reason} ->
        fanout_frame_fallback(input_signal, request, fallback_response, reason)
    end
  end

  defp frame_fanout_response(request, %FanoutPlan{} = plan, manager_response) do
    Settings.with_resolved_settings(fn ->
      manager_diagnostic = manager_diagnostic(manager_response)

      with :ok <- ensure_fanout_model_enabled(),
           :ok <- ensure_fanout_execution_roles_ready(request),
           {:ok, budget} <- plan_budget(plan, manager_diagnostic),
           {:ok, deadline_unix_ms} <- plan_deadline(budget, manager_diagnostic),
           {:ok, framed} <-
             frame_fanout_plan(request, plan, budget, deadline_unix_ms, manager_diagnostic) do
        {:ok,
         framed
         |> kickoff_response(request)
         |> copy_manager_fact(manager_response)
         |> add_admission_diagnostic(:admitted)}
      end
    end)
  end

  defp frame_fanout_plan(request, plan, budget, deadline_unix_ms, manager_diagnostic) do
    provenance = plan_provenance(plan, budget, deadline_unix_ms, manager_diagnostic)

    attrs = %{
      user_id: request.user_id,
      title: String.slice(request.operator_text, 0, 160),
      objective: request.operator_text,
      proposer_hint: %{"fanout_plan" => provenance},
      source_channel: to_string(request.channel),
      source_surface: source_surface(request.channel),
      source_thread_id: request.thread_id,
      session_id: request.session_id,
      active_app: optional_to_string(request.active_app),
      origin_receiver_account_ref: origin_field(request, :receiver_account_ref),
      origin_thread_ref_id: origin_field(request, :id),
      origin_thread_ref_digest: origin_ref_digest(request.channel_thread_ref)
    }

    fanout_framer().(attrs, FanoutPlan.child_attrs(plan))
  end

  defp ensure_fanout_model_enabled do
    case Settings.get("intent.direct_answer_model_enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :direct_answer_model_disabled}
      {:error, reason} -> {:error, {:fanout_model_setting_unavailable, reason}}
    end
  end

  defp ensure_fanout_execution_roles_ready(request) do
    context = %{request: request}
    specs = Map.new(@fanout_execution_roles, &{&1, {:role, &1}})
    readiness = model_readiness(specs, context)

    Enum.reduce_while(@fanout_execution_roles, :ok, fn role, :ok ->
      fanout_role_readiness_step(Map.get(readiness, role), role, context)
    end)
  end

  defp fanout_role_readiness_step(%{callable?: true, profile: profile}, role, context)
       when is_map(profile) do
    case Disclosure.authorize_transport(profile, context) do
      :ok -> {:cont, :ok}
      {:error, _reason} -> {:halt, {:error, {:fanout_role_transport_unavailable, role}}}
    end
  end

  defp fanout_role_readiness_step(_uncallable_or_invalid, role, _context),
    do: {:halt, {:error, {:fanout_role_unavailable, role}}}

  defp model_readiness(specs, context) do
    case Application.get_env(:allbert_assist, :runtime_model_readiness, ModelReadiness) do
      fun when is_function(fun, 2) -> fun.(specs, context)
      module when is_atom(module) -> module.check(specs, context)
      _invalid -> ModelReadiness.check(specs, context)
    end
  end

  defp fanout_frame_fallback(input_signal, request, nil, reason) do
    request = %{request | fanout_manager_mode: :off}

    case run_agent_turn(input_signal, request) do
      {:ok, response} -> {:ok, add_fanout_diagnostic(response, reason)}
      other -> other
    end
  end

  defp fanout_frame_fallback(_input_signal, _request, response, reason) do
    {:ok, add_fanout_diagnostic(response, reason)}
  end

  defp add_fanout_diagnostic(response, reason) do
    response
    |> strip_fanout_control()
    |> add_admission_diagnostic(:single_turn_fallback, fanout_failure_kind(reason))
  end

  defp fanout_failure_kind({:fanout_already_active, _parent}), do: :fanout_already_active
  defp fanout_failure_kind({:fanout_budget_exhausted, _details}), do: :fanout_budget_exhausted

  defp fanout_failure_kind({:fanout_budget_setting_unavailable, _key, _reason}),
    do: :fanout_budget_unavailable

  defp fanout_failure_kind(:fanout_plan_deadline_exhausted),
    do: :fanout_plan_deadline_exhausted

  defp fanout_failure_kind(:direct_answer_model_disabled),
    do: :direct_answer_model_disabled

  defp fanout_failure_kind({kind, :direct_answer})
       when kind in [:fanout_role_unavailable, :fanout_role_transport_unavailable],
       do: :fanout_direct_answer_unavailable

  defp fanout_failure_kind({kind, :fanout_synthesis})
       when kind in [:fanout_role_unavailable, :fanout_role_transport_unavailable],
       do: :fanout_synthesis_unavailable

  defp fanout_failure_kind(_reason), do: :fanout_frame_failed

  defp revalidation_failure_kind(:plan_request_binding_mismatch),
    do: :plan_request_binding_mismatch

  defp revalidation_failure_kind(_reason), do: :plan_revalidation_failed

  defp add_admission_diagnostic(response, outcome, reason \\ nil) do
    Response.append_diagnostic(response, FanoutDiagnostics.admission(outcome, reason))
  end

  defp copy_manager_fact(response, manager_response) do
    case FanoutDiagnostics.manager_fact(manager_response) do
      nil -> response
      fact -> Response.append_diagnostic(response, fact)
    end
  end

  defp strip_fanout_control(response) do
    response
    |> Map.delete(:parallel_work_plan)
    |> Map.delete(:parallel_work_clarification)
    |> Map.delete(:fanout_manager)
    |> strip_nested_manager_diagnostic()
    |> Map.update(:diagnostics, [], &FanoutDiagnostics.sanitize/1)
  end

  defp strip_nested_manager_diagnostic(response) when is_map(response) do
    response = strip_direct_answer_manager(response)

    case Map.fetch(response, :actions) do
      {:ok, actions} when is_list(actions) ->
        Map.put(response, :actions, Enum.map(actions, &strip_direct_answer_manager/1))

      _other ->
        response
    end
  end

  defp strip_direct_answer_manager(%{direct_answer: direct_answer} = container)
       when is_map(direct_answer) do
    sanitized =
      case Map.get(direct_answer, :diagnostic) do
        diagnostic when is_map(diagnostic) ->
          Map.put(direct_answer, :diagnostic, Map.delete(diagnostic, :manager))

        _other ->
          direct_answer
      end

    Map.put(container, :direct_answer, sanitized)
  end

  defp strip_direct_answer_manager(container), do: container

  defp manager_diagnostic(%{fanout_manager: %{} = diagnostic}), do: diagnostic
  defp manager_diagnostic(_response), do: %{}

  defp plan_budget(%FanoutPlan{source: :model, children: children}, diagnostic) do
    attempts = map_integer(diagnostic, :attempts, 1)

    case map_value(diagnostic, :budget_limits) do
      %{} = limits -> FanoutBudget.resolve(length(children), attempts, limits)
      _missing -> FanoutBudget.resolve(length(children), attempts)
    end
  end

  defp plan_budget(%FanoutPlan{source: :exact_counted, children: children}, _diagnostic),
    do: FanoutBudget.resolve(length(children), 0)

  defp plan_deadline(budget, diagnostic) do
    deadline = map_value(diagnostic, :plan_deadline_unix_ms)

    cond do
      is_integer(deadline) and deadline > System.system_time(:millisecond) ->
        {:ok, deadline}

      map_integer(diagnostic, :attempts, 0) > 0 ->
        {:error, :fanout_plan_deadline_exhausted}

      true ->
        {:ok, System.system_time(:millisecond) + budget["max_elapsed_ms"]}
    end
  end

  defp plan_provenance(plan, budget, deadline_unix_ms, diagnostic) do
    FanoutPlan.provenance(plan)
    |> Map.put("budget", budget)
    |> Map.put("deadline_unix_ms", deadline_unix_ms)
    |> maybe_put_string("manager_profile", map_value(diagnostic, :model_profile))
    |> maybe_put_string("manager_profile_sha256", map_value(diagnostic, :model_profile_sha256))
    |> Map.put("manager_attempts", map_integer(diagnostic, :attempts, 0))
  end

  defp maybe_put_string(map, _key, value) when not is_binary(value), do: map
  defp maybe_put_string(map, key, value), do: Map.put(map, key, value)

  defp map_integer(map, key, default) do
    case map_value(map, key) do
      value when is_integer(value) -> value
      _missing -> default
    end
  end

  defp map_value(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, to_string(key))

  defp fanout_framer do
    :allbert_assist
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:fanout_framer, &Fanout.frame_if_inactive/2)
  end

  defp kickoff_response(
         %{parent: parent, children: children, fanout_start_receipt: receipt},
         request
       ) do
    labels = Enum.map_join(children, "\n", &"#{&1.queue_position + 1}. #{&1.title}")

    offer? = Notify.prepare_consent_offer(parent)

    offer_text =
      if offer?,
        do: "\n\nReply `ALLBERT:NOTIFY:ON` to get reports pushed here. This offer appears once.",
        else: ""

    response =
      Response.completed(
        "I split this into #{length(children)} tasks:\n#{labels}\n\n" <>
          kickoff_delivery_message(parent) <>
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

    maybe_add_start_confirmation(response, parent, request)
  end

  defp kickoff_delivery_message(parent) do
    cond do
      Notify.live_attached_surface?(parent) ->
        "Reply in this thread to steer them. I'll show the final report here as soon as it is ready."

      Notify.autonomous_enabled?(parent) ->
        "Reply in this thread to steer them. Status and the final report will be pushed here."

      true ->
        "Reply in this thread to steer them. I'll report when you next message; enable autonomous notifications in settings to have results pushed here."
    end
  end

  defp maybe_add_start_confirmation(response, parent, request) do
    case Settings.get("objectives.fanout.confirm_before_start") do
      {:ok, true} ->
        add_start_confirmation(response, parent, request)

      _other ->
        response
    end
  end

  defp add_start_confirmation(response, parent, request) do
    case Confirmations.create(start_confirmation_attrs(parent), effect_context(%{}, request)) do
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

  defp start_acknowledged_fanout(parent) do
    if Fanout.recovery_required?(parent) do
      case Scheduler.start_fanout(parent.id) do
        {:ok, _coordinator} ->
          :ok

        {:error, _transient_reason} ->
          Fanout.wake_recovery(parent)
      end
    else
      :ok
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
  defp origin_ref_digest(ref), do: ChannelThread.canonical_ref_digest(ref)

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
    pending_reports = Fanout.pending_reports(request.user_id, request.thread_id, request)
    ensure_attached_web_reports(request, pending_reports)

    pending_report_texts =
      Enum.reject(pending_reports, fn pending ->
        Conversations.fanout_report_message?(
          request.user_id,
          request.thread_id,
          pending.parent_objective_id
        )
      end)

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
    |> maybe_put(:decomposition_overflow, Map.get(agent_response, :decomposition_overflow))
    |> maybe_put(:search_page, Map.get(agent_response, :search_page))
    |> maybe_put(:search_disclosure, Map.get(agent_response, :search_disclosure))
    |> maybe_put(:confirmation_id, Map.get(agent_response, :confirmation_id))
    |> Map.put(:pending_reports, pending_reports)
    |> attach_pending_report_text(pending_report_texts)
    |> maybe_put_media_outputs(media_outputs)
  end

  defp ensure_attached_web_reports(%{channel: channel} = request, pending_reports)
       when channel in [:live_view, "live_view"] do
    Enum.each(pending_reports, fn pending ->
      case Runner.run(
             @persist_attached_fanout_report,
             %{thread_id: request.thread_id, parent_id: pending.parent_objective_id},
             effect_context(
               %{
                 user_id: request.user_id,
                 channel: "live_view",
                 thread_id: request.thread_id
               },
               request
             )
           ) do
        {:ok, %{status: :completed}} ->
          :ok

        {:ok, response} ->
          Logger.warning(
            "Attached Web fan-in report remained noncanonical: #{inspect(Map.get(response, :error, response.status))}"
          )
      end
    end)
  end

  defp ensure_attached_web_reports(_request, _pending_reports), do: :ok

  defp attach_pending_report_text(response, []), do: response

  defp attach_pending_report_text(response, pending_reports) do
    text =
      pending_reports
      |> Enum.map_join("\n\n", fn pending -> Fanout.format_report(pending.report) end)

    Enum.reduce([:message, :model_payload, :surface_payload], response, fn field, acc ->
      Map.update(acc, field, text, fn existing -> existing <> "\n\n" <> text end)
    end)
  end

  defp persist_user_message(request, input_signal) do
    metadata =
      %{
        channel: request.channel,
        session_id: request.session_id
      }
      |> maybe_put(:active_app, request.active_app)

    with :ok <- validate_request_epoch(request) do
      Conversations.admit_user_message(request.conversation_thread, request.text, %{
        input_signal_id: input_signal.id,
        metadata: metadata,
        channel_thread_ref: request.channel_thread_ref,
        provider_message_id: request.provider_message_id,
        provider_message_part_id: request.provider_message_part_id,
        external_user_id: request.external_user_id
      })
    end
  end

  defp put_inbound_admission(request, admission) do
    request
    |> Map.put(:user_message_id, admission.message.id)
    |> Map.put(:user_message_origin, %{
      origin_thread_ref_id: admission.message.origin_thread_ref_id,
      origin_principal_digest: admission.message.origin_principal_digest,
      principal_normalizer_version: admission.message.principal_normalizer_version
    })
    |> Map.put(:channel_thread_ref, admission.channel_thread_ref)
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
    with :ok <- validate_request_epoch(request) do
      persist_assistant_message_after_validation(response, request, response_signal)
    else
      {:error, _reason} -> response
    end
  end

  defp persist_assistant_message_after_validation(response, request, response_signal) do
    case Conversations.get_thread(request.user_id, request.thread_id) do
      {:ok, thread} ->
        metadata =
          %{
            channel: request.channel,
            session_id: request.session_id
          }
          |> maybe_mark_search_result(response)
          |> maybe_put(:active_app, request.active_app)
          |> maybe_put_media_outputs(
            MediaOutputs.persistable(Map.get(response, :media_outputs, []))
          )

        attrs =
          %{
            action_log: assistant_action_log(response),
            trace_id: response.trace_id,
            response_signal_id: response_signal.id,
            metadata: metadata
          }
          |> Map.merge(Map.get(request, :user_message_origin, %{}))

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

  defp maybe_mark_search_result(metadata, %{search_page: page}) when is_map(page),
    do: Map.put(metadata, :content_kind, "search_result_render")

  defp maybe_mark_search_result(metadata, _response), do: metadata

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

    case Runner.run(
           "record_trace",
           %{turn: turn},
           effect_context(trace_context(input_signal, request), request)
         ) do
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

  defp effect_epoch_opts(request) do
    [allbert_pack_epoch: request.allbert_pack_epoch]
  end

  defp effect_context(context, request) when is_map(context) do
    context
    |> Map.put(:allbert_pack_epoch, request.allbert_pack_epoch)
  end

  defp validate_request_epoch(request), do: EffectGuard.validate(request.allbert_pack_epoch)

  defp validate_delivery_epoch(%{allbert_pack_epoch: epoch}), do: EffectGuard.validate(epoch)
  defp validate_delivery_epoch(_context), do: {:error, :product_not_ready}

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
