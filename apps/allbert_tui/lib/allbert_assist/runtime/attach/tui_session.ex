defmodule AllbertAssist.Runtime.Attach.TUISession do
  @moduledoc """
  Bounded daemon-side owner for one authenticated terminal attachment.

  This is a plain GenServer because it owns transport state, queue custody, and
  lifecycle cleanup; it has no action authority, skill composition, or durable
  state machine that would benefit from Jido.Agent. Runtime behavior remains in
  the existing TUI adapter and registered action spine.
  """

  use GenServer

  require Logger

  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Channels.Identity
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Runtime.Attach.TUIProtocol
  alias AllbertAssist.Runtime.Redactor

  @channel "tui"
  @max_control_tasks 32
  @socket_send_timeout 5_000
  @output_call_timeout 5_000
  @confirmation_call_timeout 5_000
  @render_line_limit 256
  @render_line_bytes 8 * 1_024

  @type state :: map()

  @doc false
  @spec start(keyword()) :: GenServer.on_start()
  def start(opts), do: GenServer.start(__MODULE__, opts)

  @doc false
  @spec output(GenServer.server(), term()) :: :ok | {:error, term()}
  def output(server, line), do: GenServer.call(server, {:output, line}, @output_call_timeout)

  @doc false
  @spec delivery_output(GenServer.server(), term()) :: :ok | {:error, term()}
  def delivery_output(server, line),
    do: GenServer.call(server, {:delivery_output, line}, :infinity)

  @doc false
  @spec confirmation(GenServer.server(), map()) :: :ok | {:error, term()}
  def confirmation(server, payload),
    do: GenServer.call(server, {:confirmation, payload}, @confirmation_call_timeout)

  @doc false
  @spec input_lifecycle(GenServer.server(), String.t(), Channels.Event.t(), term()) :: :ok
  def input_lifecycle(server, receipt_id, event, transition) do
    GenServer.cast(server, {:input_lifecycle, receipt_id, event, transition})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    with attach_server when is_pid(attach_server) <- Keyword.get(opts, :attach_server),
         %{} = open <- Keyword.get(opts, :open),
         {:ok, session_flow} <- TUIProtocol.new_flow(TUIProtocol.new_session_id()) do
      attach_monitor = Process.monitor(attach_server)

      state = %{
        attach_server: attach_server,
        attach_monitor: attach_monitor,
        profile: open.profile,
        terminal: open.terminal,
        session_flow: session_flow,
        session_ref: Base.url_encode64(session_flow.session_id, padding: false),
        socket: nil,
        adapter_pid: nil,
        adapter_monitor: nil,
        adapter_child_id: "tui",
        channels_supervisor:
          Keyword.get(opts, :channels_supervisor, AllbertAssist.Channels.Supervisor),
        bootstrap_fun: Keyword.get(opts, :bootstrap_fun, tui_bootstrap_fun()),
        channel_settings_fun:
          Keyword.get(opts, :channel_settings_fun, &Channels.channel_settings/1),
        adapter_module: Keyword.get(opts, :adapter_module, tui_pack_module(:adapter)),
        input_receipt_module:
          Keyword.get(opts, :input_receipt_module, tui_pack_module(:input_receipt)),
        verified_operator_id: nil,
        max_text_bytes: TUIProtocol.limits().default_max_text_bytes,
        render_revision: 0,
        render_state: :idle,
        render_status_text: "",
        render_lines: [],
        inbound_queue: :queue.new(),
        inbound_frames: 0,
        inbound_bytes: 0,
        inbound_task: nil,
        outbound_queue: :queue.new(),
        outbound_frames: 0,
        outbound_bytes: 0,
        delivery_waiters: %{},
        gap_pending?: false,
        live_receipts: MapSet.new(),
        control_tasks: %{},
        last_cancel_reason: nil,
        allbert_pack_epoch: Keyword.get(opts, :allbert_pack_epoch),
        closing?: false
      }

      {:ok, state, {:continue, :prepare}}
    else
      _invalid -> {:stop, :invalid_session_options}
    end
  end

  @impl true
  def handle_continue(:prepare, state) do
    case prepare_adapter(state) do
      {:ok, state} ->
        send(state.attach_server, {:tui_session_ready, self()})
        {:noreply, state}

      {:error, code, message, state} ->
        send(state.attach_server, {:tui_session_rejected, self(), code, message})
        {:stop, :normal, state}
    end
  end

  @impl true
  def handle_call({:output, line}, _from, state) do
    case output_entry(line, state, nil, :presentation, state.max_text_bytes) do
      {:ok, state, _custody} -> {:reply, :ok, state}
      {:error, reason, state} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delivery_output, line}, from, state) do
    case output_entry(line, state, from, :authority, Report.max_body_bytes()) do
      {:ok, state, :deferred} ->
        {:noreply, state}

      {:ok, state, :immediate} ->
        {:reply, :ok, state}

      {:error, reason, state} ->
        state = send_close(state, :overflow, "TUI output capacity was exceeded.")
        {:stop, :normal, {:error, reason}, state}
    end
  end

  def handle_call({:confirmation, payload}, _from, state) do
    state = %{state | render_state: :confirming}

    case admit_protocol(state, :confirmation, payload, :authority, nil) do
      {:ok, state, _custody} ->
        {:reply, :ok, state}

      {:error, reason, state} ->
        state = send_close(state, :overflow, "TUI output capacity was exceeded.")
        {:stop, :overflow, {:error, reason}, state}
    end
  end

  @impl true
  def handle_cast({:input_lifecycle, receipt_id, event, :in_progress}, state) do
    state =
      state
      |> Map.update!(:live_receipts, &MapSet.put(&1, receipt_id))
      |> Map.put(:render_state, :thinking)

    state =
      case state.input_receipt_module.mark_in_progress(event, %{
             allbert_pack_epoch: state.allbert_pack_epoch
           }) do
        {:ok, _event} ->
          enqueue_protocol(
            state,
            :status,
            %{
              render_revision: state.render_revision,
              state: :thinking,
              text: "Input is in progress.",
              input_receipt_id: receipt_id
            },
            :status,
            nil
          )

        {:error, reason} ->
          Logger.warning(
            "TUI receipt could not enter in-progress state: " <>
              inspect(Redactor.redact(reason))
          )

          state
      end

    cast_result(state)
  end

  def handle_cast({:input_lifecycle, receipt_id, event, {:terminal, reply}}, state) do
    outcome = terminal_outcome(reply)
    safe_refs = terminal_refs(reply)

    state =
      state
      |> Map.update!(:live_receipts, &MapSet.delete(&1, receipt_id))
      |> Map.put(:render_state, :idle)

    state =
      case state.input_receipt_module.mark_terminal(event, outcome, safe_refs, %{
             allbert_pack_epoch: state.allbert_pack_epoch
           }) do
        {:ok, terminal_event} ->
          refs = %{
            receipt_message_id: terminal_event.receipt_message_id,
            receipt_result_ref: terminal_event.receipt_result_ref
          }

          enqueue_completion(
            state,
            receipt_id,
            durable_terminal_outcome(terminal_event, outcome),
            refs,
            false
          )

        {:error, reason} ->
          Logger.warning(
            "TUI receipt terminal state could not be persisted: " <>
              inspect(Redactor.redact(reason))
          )

          enqueue_protocol(
            state,
            :error,
            TUIProtocol.error_payload(
              :outcome_unknown,
              "The input finished, but its durable outcome could not be recorded.",
              receipt_id
            ),
            :authority,
            nil
          )
      end

    cast_result(state)
  end

  def handle_cast(_message, state), do: {:noreply, state}

  @impl true
  def handle_info({:attach_socket, socket}, %{socket: nil} = state) do
    case activate_socket(socket, state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, state}
    end
  end

  def handle_info({:attach_socket, socket}, state) do
    :gen_tcp.close(socket)
    {:noreply, state}
  end

  def handle_info({:tcp, socket, payload}, %{socket: socket} = state) do
    case receive_frame(payload, state) do
      {:ok, state} ->
        {:noreply, continue_read(state)}

      {:stop, reason, state} ->
        {:stop, reason, state}
    end
  end

  def handle_info({:tcp_closed, socket}, %{socket: socket} = state),
    do: {:stop, :normal, %{state | socket: nil}}

  def handle_info({:tcp_error, socket, reason}, %{socket: socket} = state),
    do: {:stop, {:socket_error, reason}, %{state | socket: nil}}

  def handle_info(:socket_activation_failed, state),
    do: {:stop, :socket_activation_failed, state}

  def handle_info({task_ref, result}, state) when is_reference(task_ref) do
    cond do
      match?(%{task: %Task{ref: ^task_ref}}, state.inbound_task) ->
        Process.demonitor(task_ref, [:flush])

        state
        |> finish_inbound_task(result)
        |> continue_after_async()

      Map.has_key?(state.control_tasks, task_ref) ->
        {control, tasks} = Map.pop!(state.control_tasks, task_ref)
        Process.demonitor(task_ref, [:flush])

        state
        |> Map.put(:control_tasks, tasks)
        |> handle_control_result(control.kind, result)
        |> continue_after_async()

      true ->
        {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor_ref, :process, pid, reason}, state) do
    cond do
      monitor_ref == state.attach_monitor and pid == state.attach_server ->
        {:stop, :shutdown, state}

      monitor_ref == state.adapter_monitor and pid == state.adapter_pid ->
        state = send_close(state, :runtime_unavailable, "TUI runtime stopped.")
        {:stop, {:adapter_down, reason}, state}

      match?(%{task: %Task{ref: ^monitor_ref}}, state.inbound_task) ->
        state
        |> fail_inbound_task(reason)
        |> continue_after_async()

      Map.has_key?(state.control_tasks, monitor_ref) ->
        {control, tasks} = Map.pop!(state.control_tasks, monitor_ref)

        state
        |> Map.put(:control_tasks, tasks)
        |> handle_control_down(control.kind, reason)
        |> continue_after_async()

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    cancel_reason = state.last_cancel_reason || reason

    state
    |> close_socket()
    |> stop_inbound_task()
    |> stop_control_tasks()
    |> cancel_attended_work(cancel_reason)
    |> stop_adapter()
    |> release_output_waiters()

    :ok
  end

  defp prepare_adapter(state) do
    with {:ok, adapter_module} <- ensure_pack_module(state.adapter_module),
         {:ok, input_receipt_module} <- ensure_pack_module(state.input_receipt_module),
         state = %{
           state
           | adapter_module: adapter_module,
             input_receipt_module: input_receipt_module
         },
         {:ok, profile} <- effective_profile(state.profile, state.channel_settings_fun),
         state = %{state | profile: profile},
         {:ok, bootstrap} <- safe_bootstrap(state.bootstrap_fun, state.profile),
         :ok <- bootstrap_allowed(bootstrap),
         {:ok, settings} <- safe_channel_settings(state.channel_settings_fun),
         :ok <- channel_enabled(settings),
         {:ok, operator_id} <-
           Identity.resolve(@channel, state.profile, Map.get(settings, "identity_map", [])),
         :ok <- adapter_slot_available(state.channels_supervisor, state.adapter_module),
         {:ok, adapter_pid} <- start_adapter(state, settings) do
      monitor_ref = Process.monitor(adapter_pid)

      {:ok,
       %{
         state
         | adapter_pid: adapter_pid,
           adapter_monitor: monitor_ref,
           verified_operator_id: operator_id,
           max_text_bytes: max_text_bytes(settings)
       }}
    else
      {:error, :explicitly_disabled} ->
        {:error, :identity_denied, "The TUI channel is explicitly disabled.", state}

      {:error, reason} when reason in [:not_mapped, :disabled, :channel_disabled] ->
        {:error, :identity_denied, "The TUI operator identity is not enabled.", state}

      {:error, :already_attached} ->
        {:error, :already_attached, "A TUI adapter is already active.", state}

      {:error, reason} ->
        Logger.warning("TUI session preparation failed: #{inspect(Redactor.redact(reason))}")
        {:error, :runtime_unavailable, "TUI runtime preparation failed.", state}
    end
  end

  # v1.4 M13 extracted the TUI channel into its own pack; the R0 frozen DAG
  # forbids a compile-time residual-to-pack alias, so this daemon-owned
  # lifecycle resolves the pack's adapter/bootstrap/receipt modules from the
  # same channel descriptor every pack publishes through
  # `AllbertAssist.Plugin.channels/0` (see `AllbertTUI.Plugin.channels/0` and
  # the parallel doctor resolution in `AllbertAssist.Actions.Channels.ShowChannel`).
  # This process is still the lifecycle owner -- only the module identity
  # moves from compile time to runtime, and it is re-validated in
  # `prepare_adapter/1` before any adapter or receipt call is made.
  defp tui_pack_module(key) do
    case Channels.channel_descriptor(@channel) do
      {:ok, descriptor} -> Map.get(descriptor, key)
      {:error, _reason} -> nil
    end
  end

  defp tui_bootstrap_fun do
    case tui_pack_module(:identity_bootstrap) do
      module when is_atom(module) and not is_nil(module) ->
        Function.capture(module, :prepare_local_launch, 1)

      _unavailable ->
        fn _profile -> {:error, :tui_identity_bootstrap_unavailable} end
    end
  end

  # Checks loadability, not merely that a non-nil atom arrived. The descriptor
  # resolves to a module name, and dialyzer can prove that name is always a
  # non-nil atom -- so an is_atom/not-nil guard has an unreachable second clause
  # and proves nothing. What can actually fail at runtime is the pack's module
  # being absent from the code path, which is the condition worth failing on.
  defp ensure_pack_module(module) when is_atom(module) do
    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, :tui_pack_module_unavailable}
    end
  end

  defp ensure_pack_module(_invalid), do: {:error, :tui_pack_module_unavailable}

  # The terminal process cannot read Settings Central without becoming a
  # second application/runtime owner. Keep the existing operator-tunable
  # `channels.tui.profile` setting authoritative inside the daemon. A future
  # explicit client selector may still send a non-default profile additively.
  # Bootstrap may create channel settings, so the post-bootstrap policy read in
  # `prepare_adapter/1` remains separate from this fail-closed selector read.
  defp effective_profile("default", channel_settings_fun) do
    with {:ok, settings} <- safe_channel_settings(channel_settings_fun) do
      settings
      |> Map.get("profile", "default")
      |> TUIProtocol.normalize_profile()
    end
  end

  defp effective_profile(requested, _channel_settings_fun),
    do: TUIProtocol.normalize_profile(requested)

  defp safe_channel_settings(channel_settings_fun) do
    case channel_settings_fun.(@channel) do
      {:ok, %{} = settings} -> {:ok, settings}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_channel_settings, other}}
    end
  rescue
    error -> {:error, {:channel_settings_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:channel_settings_failure, kind, reason}}
  end

  defp safe_bootstrap(bootstrap_fun, profile) do
    bootstrap_fun.(profile)
  rescue
    error -> {:error, {:bootstrap_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:bootstrap_failure, kind, reason}}
  end

  defp bootstrap_allowed(%{disposition: :explicitly_disabled}),
    do: {:error, :explicitly_disabled}

  defp bootstrap_allowed(%{}), do: :ok
  defp bootstrap_allowed(_other), do: {:error, :invalid_bootstrap_result}

  defp channel_enabled(settings) do
    if Map.get(settings, "enabled", false), do: :ok, else: {:error, :channel_disabled}
  end

  # No is_atom/1 check here: the only caller is `prepare_adapter/1`, which admits
  # this module through `ensure_pack_module/1` first, and that clause's guard
  # already establishes it. M13 introduced that upstream check when the adapter
  # module moved from a compile-time alias to a runtime descriptor lookup, which
  # left the guard duplicated -- and dialyzer proved the second one unreachable.
  defp adapter_slot_available(supervisor, adapter_module) do
    registered_pid = Process.whereis(adapter_module)

    if is_pid(registered_pid) do
      {:error, :already_attached}
    else
      supervisor
      |> Supervisor.which_children()
      |> adapter_child_available(adapter_module)
    end
  rescue
    error -> {:error, {:supervisor_unavailable, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:supervisor_unavailable, reason}}
  end

  defp adapter_child_available(children, adapter_module) do
    case Enum.find(children, fn
           {id, pid, _type, _modules} -> id in ["tui", adapter_module] and is_pid(pid)
         end) do
      nil -> :ok
      _child -> {:error, :already_attached}
    end
  end

  defp start_adapter(state, settings) do
    owner = self()

    opts = [
      id: state.adapter_child_id,
      restart: :temporary,
      enabled?: true,
      profile: state.profile,
      auto_input?: false,
      emit_banner?: false,
      input_driver?: false,
      escape_monitor?: false,
      live_screen?: false,
      output_fun: &output(owner, &1),
      delivery_output_fun: &delivery_output(owner, &1),
      confirmation_fun: &confirmation(owner, &1),
      input_lifecycle_fun: &input_lifecycle(owner, &1, &2, &3),
      max_text_bytes: max_text_bytes(settings)
    ]

    child_spec = state.adapter_module.child_spec(opts)

    case Supervisor.start_child(state.channels_supervisor, child_spec) do
      {:ok, pid} -> {:ok, pid}
      {:ok, pid, _info} -> {:ok, pid}
      {:error, {:already_started, _pid}} -> {:error, :already_attached}
      {:error, :already_present} -> {:error, :already_attached}
      {:error, reason} -> {:error, {:adapter_start_failed, reason}}
    end
  end

  defp max_text_bytes(settings) do
    maximum = TUIProtocol.limits().maximum_max_text_bytes

    case Map.get(settings, "max_text_bytes", TUIProtocol.limits().default_max_text_bytes) do
      value when is_integer(value) and value >= 1 and value <= maximum -> value
      _invalid -> TUIProtocol.limits().default_max_text_bytes
    end
  end

  defp activate_socket(socket, state) do
    state = %{state | socket: socket}

    with :ok <-
           :inet.setopts(socket,
             packet_size: TUIProtocol.limits().frame_body_bytes,
             send_timeout: @socket_send_timeout,
             send_timeout_close: true,
             active: false
           ),
         {:ok, state} <- send_initial_snapshot(state),
         {:ok, state} <- drain_outbound(state),
         :ok <- :inet.setopts(socket, active: :once) do
      {:ok, state}
    else
      {:error, reason} -> {:error, {:socket_activation_failed, reason}, state}
    end
  end

  defp send_initial_snapshot(state) do
    payload = %{render_revision: 0, state: :idle, lines: [], gap?: false}

    case send_protocol_frame(state, :snapshot, payload, nil) do
      {:ok, state, _custody} -> {:ok, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp receive_frame(payload, state) do
    # Wire decoding uses the frozen protocol ceiling. The daemon-owned receipt
    # gate applies the smaller Settings Central semantic limit and returns a
    # bounded `:invalid_input` frame instead of treating ordinary oversized
    # operator text as a transport/protocol attack.
    opts = [max_text_bytes: TUIProtocol.limits().maximum_max_text_bytes]

    case TUIProtocol.decode_frame(payload, :client_to_daemon, opts) do
      {:ok, frame} ->
        accept_decoded_frame(frame, byte_size(payload), opts, state)

      {:error, reason} ->
        Logger.warning("TUI session frame decoding rejected: #{inspect(reason)}")
        stop_for_transport_error(reason, state)
    end
  end

  defp accept_decoded_frame(frame, encoded_bytes, opts, state) do
    case TUIProtocol.accept_frame(state.session_flow, :client_to_daemon, frame, opts) do
      {:ok, flow} ->
        finish_decoded_frame(state, flow, frame, encoded_bytes)

      {:error, reason} ->
        Logger.warning("TUI session frame transition rejected: #{inspect(reason)}")
        stop_for_transport_error(reason, state)
    end
  end

  defp finish_decoded_frame(state, flow, frame, encoded_bytes) do
    case finish_received_frame(state, flow, frame, encoded_bytes) do
      {:ok, state} -> received_frame_result(state)
      {:error, reason, failed_state} -> stop_for_transport_error(reason, failed_state)
    end
  end

  defp finish_received_frame(state, flow, frame, encoded_bytes) do
    state =
      state
      |> Map.put(:session_flow, flow)
      |> release_delivery_waiters(frame.ack)
      |> dispatch_frame(frame, encoded_bytes)

    if state.closing? do
      {:ok, state}
    else
      state =
        state
        |> maybe_start_inbound()
        |> maybe_enqueue_gap_snapshot()

      case drain_outbound(state) do
        {:ok, state} ->
          send_cumulative_ack_carrier_if_due(state)

        {:error, reason, state} ->
          Logger.warning("TUI session outbound drain failed: #{inspect(reason)}")
          {:error, reason, state}
      end
    end
  end

  defp received_frame_result(%{closing?: true} = state), do: {:stop, :normal, state}
  defp received_frame_result(state), do: {:ok, state}

  defp dispatch_frame(state, %{frame: frame} = envelope, encoded_bytes)
       when frame in [:input, :resize, :confirmation],
       do: enqueue_inbound(state, envelope, encoded_bytes)

  defp dispatch_frame(state, %{frame: :cancel, payload: %{reason: reason}}, _encoded_bytes) do
    adapter_module = state.adapter_module
    adapter_pid = state.adapter_pid

    state
    |> Map.put(:last_cancel_reason, reason)
    |> start_control_task({:cancel, reason}, fn ->
      adapter_module.cancel_current_turn(adapter_pid, reason)
    end)
  end

  defp dispatch_frame(state, %{frame: :ack}, _encoded_bytes), do: state

  defp dispatch_frame(state, %{frame: :detach}, _encoded_bytes) do
    state
    |> send_close(:client_detach, "TUI client detached.")
    |> Map.put(:closing?, true)
  end

  defp enqueue_inbound(state, frame, encoded_bytes) do
    entry = %{frame: frame.frame, payload: frame.payload, bytes: encoded_bytes}
    {queue, frames, bytes} = coalesce_inbound_resize(entry, state)
    limits = TUIProtocol.limits().daemon_inbound

    if frames + 1 <= limits.frames and bytes + encoded_bytes <= limits.bytes do
      %{
        state
        | inbound_queue: :queue.in(entry, queue),
          inbound_frames: frames + 1,
          inbound_bytes: bytes + encoded_bytes
      }
    else
      send_close(state, :overflow, "TUI input capacity was exceeded.")
    end
  end

  defp coalesce_inbound_resize(%{frame: :resize}, state) do
    entries = :queue.to_list(state.inbound_queue)
    retained = Enum.reject(entries, &(&1.frame == :resize))
    dropped = entries -- retained

    {
      :queue.from_list(retained),
      state.inbound_frames - length(dropped),
      state.inbound_bytes - Enum.sum(Enum.map(dropped, & &1.bytes))
    }
  end

  defp coalesce_inbound_resize(_entry, state),
    do: {state.inbound_queue, state.inbound_frames, state.inbound_bytes}

  defp maybe_start_inbound(%{closing?: true} = state), do: state
  defp maybe_start_inbound(%{inbound_task: task} = state) when not is_nil(task), do: state

  defp maybe_start_inbound(state) do
    case :queue.out(state.inbound_queue) do
      {:empty, _queue} ->
        state

      {{:value, %{frame: :resize, payload: terminal} = entry}, queue} ->
        state
        |> pop_inbound_entry(queue, entry)
        |> Map.update!(:terminal, &Map.merge(&1, terminal))
        |> maybe_start_inbound()

      {{:value, entry}, queue} ->
        state
        |> pop_inbound_entry(queue, entry)
        |> start_inbound_task(entry)
    end
  end

  defp pop_inbound_entry(state, queue, entry) do
    %{
      state
      | inbound_queue: queue,
        inbound_frames: state.inbound_frames - 1,
        inbound_bytes: state.inbound_bytes - entry.bytes
    }
  end

  defp start_inbound_task(state, entry) do
    receipt_id = get_in(entry, [:payload, :input_receipt_id])
    receipt_was_live? = is_binary(receipt_id) and MapSet.member?(state.live_receipts, receipt_id)

    context = %{
      adapter_module: state.adapter_module,
      adapter_pid: state.adapter_pid,
      input_receipt_module: state.input_receipt_module,
      duplicate_owner: if(receipt_was_live?, do: :live, else: :orphaned),
      max_text_bytes: state.max_text_bytes,
      profile: state.profile,
      session_ref: state.session_ref,
      verified_operator_id: state.verified_operator_id,
      allbert_pack_epoch: state.allbert_pack_epoch
    }

    task =
      Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor, fn ->
        run_inbound(entry, context)
      end)

    state =
      if is_binary(receipt_id),
        do: Map.update!(state, :live_receipts, &MapSet.put(&1, receipt_id)),
        else: state

    %{
      state
      | inbound_task: %{
          task: task,
          entry: entry,
          receipt_id: receipt_id,
          receipt_was_live?: receipt_was_live?
        }
    }
  rescue
    error ->
      state
      |> inbound_start_error(entry, {:task_start_failed, Exception.message(error)})
      |> maybe_start_inbound()
  catch
    :exit, reason ->
      state
      |> inbound_start_error(entry, {:task_start_failed, reason})
      |> maybe_start_inbound()
  end

  defp run_inbound(%{frame: :input, payload: payload}, context) do
    attrs = %{
      verified_operator_id: context.verified_operator_id,
      profile: context.profile,
      input_receipt_id: payload.input_receipt_id,
      text: payload.text,
      max_text_bytes: context.max_text_bytes,
      session_id: context.session_ref,
      allbert_pack_epoch: context.allbert_pack_epoch
    }

    case context.input_receipt_module.gate(attrs, duplicate_owner: context.duplicate_owner) do
      {:ok, %{disposition: :dispatch, event: event, normalized_text: text}} ->
        admit_input(context, payload.input_receipt_id, text, event)

      {:ok, %{disposition: :duplicate} = duplicate} ->
        {:input_duplicate, payload.input_receipt_id, duplicate}

      {:error, reason} ->
        {:input_error, payload.input_receipt_id, reason}
    end
  end

  defp run_inbound(
         %{
           frame: :confirmation,
           payload: %{confirmation_id: confirmation_id, decision: decision}
         },
         context
       ) do
    {:confirmation_result, confirmation_id,
     context.adapter_module.confirm(context.adapter_pid, confirmation_id, decision)}
  end

  defp admit_input(context, receipt_id, text, event) do
    case context.input_receipt_module.mark_admitted(event, %{}, %{
           allbert_pack_epoch: context.allbert_pack_epoch
         }) do
      {:ok, admitted_event} ->
        case context.adapter_module.submit_admitted(
               context.adapter_pid,
               text,
               admitted_event,
               receipt_id
             ) do
          {:ok, {:accepted, ^receipt_id}} ->
            {:input_admitted, receipt_id}

          {:error, reason} ->
            _ =
              context.input_receipt_module.mark_terminal(admitted_event, :failed, %{}, %{
                allbert_pack_epoch: context.allbert_pack_epoch
              })

            {:input_error, receipt_id, reason}
        end

      {:error, reason} ->
        {:input_error, receipt_id, reason}
    end
  end

  defp render_duplicate(receipt_id, %{state: state} = duplicate, session_state)
       when state in [:completed, :rejected, :failed, :outcome_unknown] do
    outcome = duplicate.outcome || state
    refs = %{receipt_message_id: duplicate.message_id, receipt_result_ref: duplicate.result_ref}
    enqueue_completion(session_state, receipt_id, outcome, refs, true)
  end

  defp render_duplicate(receipt_id, _duplicate, state) do
    enqueue_protocol(
      state,
      :status,
      %{
        render_revision: state.render_revision,
        state: :thinking,
        text: "Input is already admitted or in progress.",
        input_receipt_id: receipt_id
      },
      :status,
      nil
    )
  end

  defp finish_inbound_task(state, result) do
    task_state = state.inbound_task
    %{receipt_id: receipt_id, receipt_was_live?: receipt_was_live?} = task_state
    state = %{state | inbound_task: nil}

    state =
      case result do
        {:input_admitted, ^receipt_id} ->
          state
          |> Map.put(:render_state, :thinking)
          |> enqueue_protocol(
            :status,
            %{
              render_revision: state.render_revision,
              state: :thinking,
              text: "Input admitted.",
              input_receipt_id: receipt_id
            },
            :status,
            nil
          )

        {:input_duplicate, ^receipt_id, duplicate} ->
          state = maybe_release_duplicate_receipt(state, receipt_id, duplicate, receipt_was_live?)
          render_duplicate(receipt_id, duplicate, state)

        {:input_error, ^receipt_id, reason} ->
          state
          |> maybe_remove_task_receipt(receipt_id, receipt_was_live?)
          |> enqueue_input_error(receipt_id, reason)

        {:confirmation_result, confirmation_id, confirmation_result} ->
          handle_control_result(
            state,
            {:confirmation, confirmation_id},
            confirmation_result
          )

        _other ->
          inbound_start_error(state, task_state.entry, :invalid_task_result)
      end

    maybe_start_inbound(state)
  end

  defp fail_inbound_task(state, reason) do
    %{entry: entry, receipt_id: receipt_id, receipt_was_live?: receipt_was_live?} =
      state.inbound_task

    state =
      state
      |> Map.put(:inbound_task, nil)
      |> maybe_remove_task_receipt(receipt_id, receipt_was_live?)
      |> inbound_start_error(entry, {:task_failed, reason})

    maybe_start_inbound(state)
  end

  defp inbound_start_error(state, %{frame: :input, payload: payload}, reason),
    do: enqueue_input_error(state, payload.input_receipt_id, reason)

  defp inbound_start_error(state, %{frame: :confirmation, payload: payload}, _reason) do
    enqueue_protocol(
      state,
      :error,
      TUIProtocol.error_payload(
        :confirmation_rejected,
        "The confirmation could not be applied.",
        nil
      ),
      :authority,
      nil
    )
    |> then(fn next ->
      Logger.warning(
        "TUI confirmation task failed: " <>
          inspect(Redactor.redact(payload.confirmation_id))
      )

      next
    end)
  end

  defp inbound_start_error(state, _entry, _reason), do: state

  defp maybe_release_duplicate_receipt(state, receipt_id, duplicate, receipt_was_live?) do
    if duplicate.state in [:completed, :rejected, :failed, :outcome_unknown] and
         not receipt_was_live?,
       do: Map.update!(state, :live_receipts, &MapSet.delete(&1, receipt_id)),
       else: state
  end

  defp maybe_remove_task_receipt(state, receipt_id, false) when is_binary(receipt_id),
    do: Map.update!(state, :live_receipts, &MapSet.delete(&1, receipt_id))

  defp maybe_remove_task_receipt(state, _receipt_id, _receipt_was_live?), do: state

  defp continue_after_async(%{closing?: true} = state), do: {:stop, :normal, state}

  defp continue_after_async(state) do
    state = maybe_enqueue_gap_snapshot(state)

    case drain_outbound(state) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} -> {:stop, reason, state}
    end
  end

  defp enqueue_input_error(state, receipt_id, reason) do
    {code, message} = input_error(reason)

    enqueue_protocol(
      state,
      :error,
      TUIProtocol.error_payload(code, message, receipt_id),
      :authority,
      nil
    )
  end

  defp input_error(reason) when reason in [:invalid_input, :invalid_receipt, :invalid_identity],
    do: {:invalid_input, "Input is invalid."}

  defp input_error(:receipt_conflict),
    do: {:receipt_conflict, "This receipt id is already bound to different input."}

  defp input_error(:receipt_key_unavailable),
    do: {:receipt_key_unavailable, "Receipt integrity material is unavailable."}

  defp input_error(:input_queue_full),
    do: {:runtime_error, "The TUI input queue is full."}

  defp input_error(_reason), do: {:runtime_error, "Input admission failed."}

  defp enqueue_completion(state, receipt_id, outcome, refs, duplicate?) do
    result_ref = Map.get(refs, :receipt_result_ref)

    enqueue_protocol(
      state,
      :completion,
      %{
        input_receipt_id: receipt_id,
        outcome: outcome,
        duplicate?: duplicate?,
        result_ref: result_ref,
        lines: []
      },
      :authority,
      nil
    )
  end

  defp start_control_task(state, _kind, _fun)
       when map_size(state.control_tasks) >= @max_control_tasks do
    enqueue_protocol(
      state,
      :error,
      TUIProtocol.error_payload(:runtime_error, "Control queue is full.", nil),
      :authority,
      nil
    )
  end

  defp start_control_task(state, kind, fun) do
    task = Task.Supervisor.async_nolink(AllbertAssist.TaskSupervisor, fun)
    put_in(state.control_tasks[task.ref], %{task: task, kind: kind})
  rescue
    error ->
      Logger.warning("TUI control task could not start: #{Exception.message(error)}")

      enqueue_protocol(
        state,
        :error,
        TUIProtocol.error_payload(:runtime_error, "Control could not start.", nil),
        :authority,
        nil
      )
  end

  defp handle_control_result(state, {:confirmation, _confirmation_id}, {:ok, _result}),
    do: state

  defp handle_control_result(state, {:confirmation, _confirmation_id}, _result),
    do: enqueue_confirmation_rejected(state)

  defp handle_control_result(state, {:cancel, _reason}, result)
       when result in [:ok, {:ok, :cancelled}, {:ok, :idle}],
       do: state

  defp handle_control_result(state, {:cancel, _reason}, _result) do
    enqueue_protocol(
      state,
      :error,
      TUIProtocol.error_payload(:runtime_error, "The active turn could not be cancelled.", nil),
      :authority,
      nil
    )
  end

  defp handle_control_down(state, _kind, :normal), do: state

  defp handle_control_down(state, {:confirmation, _confirmation_id}, _reason),
    do: enqueue_confirmation_rejected(state)

  defp handle_control_down(state, {:cancel, _reason}, _task_reason) do
    enqueue_protocol(
      state,
      :error,
      TUIProtocol.error_payload(:runtime_error, "The cancellation request failed.", nil),
      :authority,
      nil
    )
  end

  defp enqueue_confirmation_rejected(state) do
    enqueue_protocol(
      state,
      :error,
      TUIProtocol.error_payload(
        :confirmation_rejected,
        "The confirmation was not applied.",
        nil
      ),
      :authority,
      nil
    )
  end

  defp cast_result(%{closing?: true} = state), do: {:stop, :overflow, state}
  defp cast_result(state), do: {:noreply, state}

  defp output_entry(line, state, waiter, priority, max_text_bytes) do
    with {:ok, lines} <- render_lines(line, max_text_bytes) do
      revision = state.render_revision + 1
      payload = %{render_revision: revision, mode: :append, lines: lines}

      state =
        state
        |> Map.put(:render_revision, revision)
        |> Map.put(:render_state, :streaming)
        |> remember_render_lines(lines, max_text_bytes)

      case admit_protocol(state, :delta, payload, priority, waiter) do
        {:ok, state, custody} -> {:ok, state, custody}
        {:error, reason, state} -> {:error, reason, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp enqueue_protocol(state, frame, payload, priority, waiter) do
    state = remember_render_state(state, frame, payload)

    case admit_protocol(state, frame, payload, priority, waiter) do
      {:ok, state, _custody} -> state
      {:error, reason, state} -> overflow_or_close(priority, reason, state)
    end
  end

  defp remember_render_state(state, :status, %{state: render_state, text: text}),
    do: %{state | render_state: render_state, render_status_text: text}

  defp remember_render_state(state, :completion, %{outcome: outcome}) do
    %{state | render_state: :idle, render_status_text: "Input #{outcome}."}
  end

  defp remember_render_state(state, :error, %{message: message}),
    do: %{state | render_state: :error, render_status_text: message}

  defp remember_render_state(state, _frame, _payload), do: state

  defp admit_protocol(state, frame, payload, priority, waiter) do
    entry = queue_entry(state, frame, payload, priority, waiter)

    if is_nil(state.socket) or state.outbound_frames > 0 do
      queue_outbound(entry, state)
    else
      case send_protocol_frame(state, frame, payload, waiter) do
        {:ok, state, custody} -> {:ok, state, custody}
        {:error, :overflow, state} -> queue_outbound(entry, state)
        {:error, reason, state} -> {:error, reason, state}
      end
    end
  end

  defp queue_outbound(entry, state) do
    case coalesce_for_entry(entry, state) do
      {:absorbed, state} ->
        {:ok, state, :immediate}

      {:enqueue, entry, state} ->
        entries = :queue.to_list(state.outbound_queue) ++ [entry]

        if outbound_fits?(entries) do
          {:ok, put_outbound_entries(state, entries), waiter_custody(entry.waiter)}
        else
          queue_under_pressure(entry, entries, state)
        end
    end
  end

  defp queue_under_pressure(entry, entries, state) do
    {entries, dropped_presentation?} =
      Enum.reduce(
        TUIProtocol.pressure_drop_order(),
        {entries, false},
        fn frame, {retained, dropped?} ->
          {retained, dropped_frame?} = drop_oldest_until_fit(retained, frame)
          {retained, dropped? or dropped_frame?}
        end
      )

    cond do
      outbound_fits?(entries) and dropped_presentation? ->
        recover_presentation_gap(entry, entries, state)

      outbound_fits?(entries) ->
        {:ok, put_outbound_entries(state, entries), waiter_custody(entry.waiter)}

      entry.priority in [:presentation, :status] ->
        recover_presentation_gap(entry, Enum.drop(entries, -1), state)

      true ->
        {:error, :overflow, state}
    end
  end

  defp recover_presentation_gap(entry, entries, state) do
    retained = Enum.reject(entries, &droppable_presentation_entry?/1)
    snapshot = gap_snapshot_entry(state)
    recovered = retained ++ [snapshot]

    cond do
      outbound_fits?(recovered) ->
        {:ok,
         recovered
         |> then(&put_outbound_entries(%{state | gap_pending?: false}, &1)),
         waiter_custody(entry.waiter)}

      entry.priority == :authority and outbound_fits?(retained) ->
        {:ok, put_outbound_entries(%{state | gap_pending?: true}, retained), :deferred}

      entry.priority in [:presentation, :status] ->
        {:ok, put_outbound_entries(%{state | gap_pending?: true}, retained), :immediate}

      true ->
        {:error, :overflow, state}
    end
  end

  defp drop_oldest_until_fit(entries, frame) do
    if outbound_fits?(entries) do
      {entries, false}
    else
      drop_oldest_matching(entries, frame)
    end
  end

  defp drop_oldest_matching(entries, frame) do
    case Enum.find_index(entries, &droppable_frame?(&1, frame)) do
      nil ->
        {entries, false}

      index ->
        {_dropped, entries} = List.pop_at(entries, index)
        {entries, _more_dropped?} = drop_oldest_until_fit(entries, frame)
        {entries, true}
    end
  end

  defp droppable_frame?(entry, frame) do
    entry.frame == frame and droppable_presentation_entry?(entry)
  end

  defp outbound_fits?(entries) do
    limits = TUIProtocol.limits().daemon_outbound_unsent
    length(entries) <= limits.frames and Enum.sum(Enum.map(entries, & &1.bytes)) <= limits.bytes
  end

  defp put_outbound_entries(state, entries) do
    %{
      state
      | outbound_queue: :queue.from_list(entries),
        outbound_frames: length(entries),
        outbound_bytes: Enum.sum(Enum.map(entries, & &1.bytes))
    }
  end

  defp droppable_presentation_entry?(entry) do
    entry.frame in [:snapshot, :delta, :status] and
      entry.priority in [:presentation, :status] and is_nil(entry.waiter)
  end

  defp gap_snapshot_entry(state) do
    queue_entry(
      state,
      :snapshot,
      %{
        render_revision: state.render_revision,
        state: state.render_state,
        lines: state.render_lines,
        gap?: true
      },
      :presentation,
      nil
    )
  end

  defp drain_outbound(%{socket: nil} = state), do: {:ok, state}

  defp drain_outbound(state) do
    case :queue.out(state.outbound_queue) do
      {:empty, _queue} ->
        {:ok, state}

      {{:value, entry}, queue} ->
        next = %{
          state
          | outbound_queue: queue,
            outbound_frames: state.outbound_frames - 1,
            outbound_bytes: state.outbound_bytes - entry.bytes
        }

        case send_protocol_frame(next, entry.frame, entry.payload, entry.waiter) do
          {:ok, next, _custody} ->
            drain_outbound(next)

          {:error, :overflow, next} ->
            {:ok,
             %{
               next
               | outbound_queue: :queue.in_r(entry, next.outbound_queue),
                 outbound_frames: next.outbound_frames + 1,
                 outbound_bytes: next.outbound_bytes + entry.bytes
             }}

          {:error, reason, next} ->
            {:error, reason, next}
        end
    end
  end

  defp send_protocol_frame(state, frame, payload, waiter) do
    with {:ok, envelope, flow} <-
           TUIProtocol.send_frame(state.session_flow, :daemon_to_client, frame, payload),
         :ok <- :gen_tcp.send(state.socket, :erlang.term_to_binary(envelope)) do
      waiters =
        if waiter,
          do: Map.put(state.delivery_waiters, envelope.seq, waiter),
          else: state.delivery_waiters

      {:ok, %{state | session_flow: flow, delivery_waiters: waiters}, waiter_custody(waiter)}
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  # Protocol v1 intentionally has no daemon-to-client `:ack` frame. When a
  # quiet client frame leaves the cumulative ack due after the normal outbound
  # drain, mirror the current bounded status as a semantic no-op carrier. This
  # releases the client's retained window without clearing meaningful status.
  defp send_cumulative_ack_carrier_if_due(%{closing?: true} = state), do: {:ok, state}

  defp send_cumulative_ack_carrier_if_due(%{session_flow: %{ack_due?: true}} = state) do
    payload = %{
      render_revision: state.render_revision,
      state: state.render_state,
      text: state.render_status_text,
      input_receipt_id: nil
    }

    case send_protocol_frame(state, :status, payload, nil) do
      {:ok, state, _custody} -> {:ok, state}
      {:error, reason, state} -> {:error, reason, state}
    end
  end

  defp send_cumulative_ack_carrier_if_due(state), do: {:ok, state}

  defp release_delivery_waiters(state, acknowledged_seq) do
    {released, retained} =
      Enum.split_with(state.delivery_waiters, fn {seq, _from} -> seq <= acknowledged_seq end)

    Enum.each(released, fn {_seq, from} -> GenServer.reply(from, :ok) end)
    %{state | delivery_waiters: Map.new(retained)}
  end

  defp maybe_enqueue_gap_snapshot(%{gap_pending?: false} = state), do: state

  defp maybe_enqueue_gap_snapshot(state) do
    payload = %{
      render_revision: state.render_revision,
      state: state.render_state,
      lines: state.render_lines,
      gap?: true
    }

    case admit_protocol(%{state | gap_pending?: false}, :snapshot, payload, :presentation, nil) do
      {:ok, state, _custody} -> state
      {:error, _reason, state} -> %{state | gap_pending?: true}
    end
  end

  defp queue_entry(state, frame, payload, priority, waiter) do
    envelope = %{
      kind: :tui_session,
      session_protocol: TUIProtocol.session_protocol(),
      frame: frame,
      session_id: state.session_flow.session_id,
      seq: max(state.session_flow.next_send_seq || 1, 1),
      ack: state.session_flow.ack_to_send,
      payload: payload
    }

    %{
      frame: frame,
      payload: payload,
      priority: priority,
      waiter: waiter,
      bytes: envelope |> :erlang.term_to_binary() |> byte_size()
    }
  end

  defp waiter_custody(nil), do: :immediate
  defp waiter_custody(_from), do: :deferred

  defp coalesce_for_entry(%{frame: :snapshot} = entry, state) do
    entries =
      state.outbound_queue
      |> :queue.to_list()
      |> Enum.reject(fn queued ->
        queued.frame == :snapshot and droppable_presentation_entry?(queued)
      end)

    {:enqueue, entry, put_outbound_entries(state, entries)}
  end

  defp coalesce_for_entry(%{frame: :status, payload: payload} = entry, state) do
    if gap_snapshot_queued?(state) and droppable_presentation_entry?(entry) do
      {:absorbed, replace_queued_gap_snapshot(state)}
    else
      replace_adjacent_entry(state, entry, fn previous ->
        previous.frame == :status and
          previous.payload.render_revision == payload.render_revision
      end)
    end
  end

  defp coalesce_for_entry(%{frame: :delta, payload: payload} = entry, state) do
    if gap_snapshot_queued?(state) and droppable_presentation_entry?(entry) do
      {:absorbed, replace_queued_gap_snapshot(state)}
    else
      coalesce_adjacent_delta(state, entry, payload)
    end
  end

  defp coalesce_for_entry(entry, state), do: {:enqueue, entry, state}

  defp coalesce_adjacent_delta(state, entry, payload) do
    entries = :queue.to_list(state.outbound_queue)

    case List.pop_at(entries, -1) do
      {previous, preceding}
      when is_map(previous) and previous.frame == :delta and
             previous.payload.render_revision == payload.render_revision ->
        maybe_reduce_adjacent_delta(state, entry, previous, payload, preceding)

      _other ->
        {:enqueue, entry, state}
    end
  end

  defp maybe_reduce_adjacent_delta(state, entry, previous, payload, preceding) do
    if droppable_presentation_entry?(entry) and droppable_presentation_entry?(previous),
      do: replace_with_reduced_delta(state, entry, previous, payload, preceding),
      else: {:enqueue, entry, state}
  end

  defp replace_with_reduced_delta(state, entry, previous, payload, preceding) do
    case TUIProtocol.reduce_adjacent_deltas(previous.payload, payload) do
      {:ok, reduced_payload} ->
        reduced = queue_entry(state, :delta, reduced_payload, entry.priority, nil)
        {:absorbed, put_outbound_entries(state, preceding ++ [reduced])}

      :no_reduction ->
        {:enqueue, entry, state}
    end
  end

  defp gap_snapshot_queued?(state) do
    Enum.any?(:queue.to_list(state.outbound_queue), fn
      %{frame: :snapshot, payload: %{gap?: true}} -> true
      _entry -> false
    end)
  end

  defp replace_queued_gap_snapshot(state) do
    retained =
      state.outbound_queue
      |> :queue.to_list()
      |> Enum.reject(&droppable_presentation_entry?/1)

    put_outbound_entries(state, retained ++ [gap_snapshot_entry(state)])
  end

  defp replace_adjacent_entry(state, entry, predicate) do
    entries = :queue.to_list(state.outbound_queue)

    case List.pop_at(entries, -1) do
      {previous, preceding} when is_map(previous) ->
        if predicate.(previous),
          do: {:absorbed, put_outbound_entries(state, preceding ++ [entry])},
          else: {:enqueue, entry, state}

      _other ->
        {:enqueue, entry, state}
    end
  end

  defp remember_render_lines(state, new_lines, max_text_bytes) do
    render_limit = min(max_text_bytes, 48 * 1_024)

    {lines, _bytes, _count} =
      state.render_lines
      |> Kernel.++(new_lines)
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, 0}, fn line, {kept, bytes, count} ->
        if count < 256 and bytes + byte_size(line) <= render_limit do
          {:cont, {[line | kept], bytes + byte_size(line), count + 1}}
        else
          {:halt, {kept, bytes, count}}
        end
      end)

    %{state | render_lines: lines}
  end

  defp overflow_or_close(priority, _reason, state) when priority in [:presentation, :status],
    do: %{state | gap_pending?: true}

  defp overflow_or_close(_priority, _reason, state),
    do: send_close(state, :overflow, "TUI output capacity was exceeded.")

  defp stop_for_transport_error(reason, state) do
    code =
      if reason in [:frame_too_large, :sequence_error, :ack_error],
        do: reason,
        else: :protocol_error

    state = send_close(state, code, "TUI transport error.")
    {:stop, reason, state}
  end

  defp send_close(%{socket: nil} = state, _code, _message), do: %{state | closing?: true}
  defp send_close(%{closing?: true} = state, _code, _message), do: state

  defp send_close(state, code, message) do
    state
    |> retain_terminal_outbound()
    |> drain_before_close(code, message)
  end

  defp retain_terminal_outbound(state) do
    entries =
      state.outbound_queue
      |> :queue.to_list()
      |> Enum.reject(&droppable_presentation_entry?/1)

    put_outbound_entries(state, entries)
  end

  defp drain_before_close(state, code, message) do
    case drain_outbound(state) do
      {:ok, %{outbound_frames: 0} = state} ->
        send_close_frame(state, code, message)

      {:ok, state} ->
        state
        |> fail_queued_output_waiters()
        |> clear_outbound()
        |> send_close_frame(:overflow, "TUI output capacity was exceeded.")

      {:error, _reason, state} ->
        state
        |> fail_queued_output_waiters()
        |> clear_outbound()
        |> Map.put(:closing?, true)
    end
  end

  defp send_close_frame(state, code, message) do
    payload = TUIProtocol.close_payload(code, message)

    state =
      case send_protocol_frame(state, :close, payload, nil) do
        {:ok, next, _custody} -> next
        {:error, _reason, next} -> next
      end

    %{state | closing?: true}
  end

  defp fail_queued_output_waiters(state) do
    state.outbound_queue
    |> :queue.to_list()
    |> Enum.each(fn
      %{waiter: nil} -> :ok
      %{waiter: from} -> GenServer.reply(from, {:error, :session_closed})
    end)

    state
  end

  defp clear_outbound(state), do: put_outbound_entries(state, [])

  defp continue_read(%{socket: socket} = state) when is_port(socket) do
    case :inet.setopts(socket, active: :once) do
      :ok ->
        state

      {:error, _reason} ->
        send(self(), :socket_activation_failed)
        state
    end
  end

  defp continue_read(state), do: state

  defp terminal_outcome({:ok, :rejected}), do: :rejected
  defp terminal_outcome({:ok, {:rejected, _reason}}), do: :rejected
  defp terminal_outcome({:ok, _response}), do: :completed

  defp terminal_outcome({:error, reason})
       when reason in [
              :empty_text,
              :not_mapped,
              :disabled,
              :wrong_channel,
              :wrong_user,
              :channel_message_inbound_denied,
              :confirmation_rejected
            ],
       do: :rejected

  defp terminal_outcome(_reply), do: :failed

  defp durable_terminal_outcome(%Event{receipt_outcome: "completed"}, _fallback),
    do: :completed

  defp durable_terminal_outcome(%Event{receipt_outcome: "rejected"}, _fallback),
    do: :rejected

  defp durable_terminal_outcome(%Event{receipt_outcome: "failed"}, _fallback), do: :failed
  defp durable_terminal_outcome(_event, fallback), do: fallback

  defp terminal_refs(reply) do
    response =
      case reply do
        {:ok, {:processed, %Event{} = event, _rendered_lines}} -> event
        {:ok, %{} = response} -> response
        %{} = response -> response
        _other -> %{}
      end

    %{}
    |> maybe_safe_ref(:input_signal_id, response_value(response, :input_signal_id))
    |> maybe_safe_ref(:thread_id, response_value(response, :thread_id))
    |> maybe_safe_ref(:trace_id, response_value(response, :trace_id))
    |> maybe_safe_ref(:receipt_message_id, response_value(response, :message_id))
    |> maybe_safe_ref(:receipt_result_ref, response_value(response, :result_ref))
  end

  defp response_value(response, key),
    do: Map.get(response, key) || Map.get(response, Atom.to_string(key))

  defp maybe_safe_ref(map, _key, nil), do: map
  defp maybe_safe_ref(map, key, value) when is_binary(value), do: Map.put(map, key, value)
  defp maybe_safe_ref(map, _key, _value), do: map

  defp render_lines(line, max_text_bytes) do
    rendered = line |> Owl.Data.to_chardata() |> IO.iodata_to_binary()
    output_limit = min(max_text_bytes, 48 * 1_024)

    cond do
      not String.valid?(rendered) -> {:error, :invalid_output}
      byte_size(rendered) > output_limit -> {:error, :output_too_large}
      true -> logical_render_lines(rendered)
    end
  rescue
    _error -> {:error, :invalid_output}
  end

  defp logical_render_lines(""), do: {:ok, []}

  defp logical_render_lines(rendered) do
    lines =
      rendered
      |> String.replace("\r\n", "\n")
      |> String.split("\n", trim: false)
      |> Enum.flat_map(fn
        "" -> [""]
        line -> chunk_utf8(line, @render_line_bytes)
      end)

    if length(lines) <= @render_line_limit,
      do: {:ok, lines},
      else: {:error, :output_too_large}
  end

  defp chunk_utf8(text, max_bytes), do: chunk_utf8(text, max_bytes, [], [], 0)

  defp chunk_utf8(<<>>, _max_bytes, chunks, current, _bytes) do
    chunk = current |> Enum.reverse() |> IO.iodata_to_binary()
    chunks = if chunk == "", do: chunks, else: [chunk | chunks]
    Enum.reverse(chunks)
  end

  defp chunk_utf8(<<codepoint::utf8, rest::binary>>, max_bytes, chunks, current, bytes) do
    encoded = <<codepoint::utf8>>

    if bytes + byte_size(encoded) > max_bytes do
      chunk = current |> Enum.reverse() |> IO.iodata_to_binary()
      chunk_utf8(rest, max_bytes, [chunk | chunks], [encoded], byte_size(encoded))
    else
      chunk_utf8(rest, max_bytes, chunks, [encoded | current], bytes + byte_size(encoded))
    end
  end

  defp cancel_attended_work(%{adapter_pid: pid} = state, reason) when is_pid(pid) do
    _ =
      GenServer.call(
        pid,
        {:cancel_current_turn, normalize_cancel_reason(reason)},
        1_000
      )

    state
  catch
    :exit, _reason -> state
  end

  defp cancel_attended_work(state, _reason), do: state

  defp normalize_cancel_reason(:operator_interrupt), do: :operator_interrupt
  defp normalize_cancel_reason(_reason), do: :operator_escape

  defp stop_inbound_task(%{inbound_task: %{task: %Task{} = task}} = state) do
    _ = Task.shutdown(task, :brutal_kill)
    %{state | inbound_task: nil}
  end

  defp stop_inbound_task(state), do: state

  defp stop_control_tasks(state) do
    Enum.each(state.control_tasks, fn {_ref, %{task: %Task{} = task}} ->
      _ = Task.shutdown(task, :brutal_kill)
    end)

    %{state | control_tasks: %{}}
  end

  defp stop_adapter(%{adapter_pid: nil} = state), do: state

  defp stop_adapter(state) do
    if state.adapter_monitor, do: Process.demonitor(state.adapter_monitor, [:flush])

    _ = Supervisor.terminate_child(state.channels_supervisor, state.adapter_child_id)
    _ = Supervisor.delete_child(state.channels_supervisor, state.adapter_child_id)
    %{state | adapter_pid: nil, adapter_monitor: nil}
  catch
    :exit, _reason -> %{state | adapter_pid: nil, adapter_monitor: nil}
  end

  defp close_socket(%{socket: socket} = state) when is_port(socket) do
    :gen_tcp.close(socket)
    %{state | socket: nil}
  end

  defp close_socket(state), do: state

  defp release_output_waiters(state) do
    Enum.each(state.delivery_waiters, fn {_seq, from} ->
      GenServer.reply(from, {:error, :session_closed})
    end)

    state.outbound_queue
    |> :queue.to_list()
    |> Enum.each(fn
      %{waiter: nil} -> :ok
      %{waiter: from} -> GenServer.reply(from, {:error, :session_closed})
    end)

    state
  end
end
