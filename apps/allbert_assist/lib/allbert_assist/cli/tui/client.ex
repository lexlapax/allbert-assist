defmodule AllbertAssist.CLI.Tui.Client do
  @moduledoc """
  Bounded Attach client for one local terminal session.

  This is a synchronous plain-process client rather than a GenServer: the
  release launcher process already owns the one blocking terminal lifecycle,
  and no named state, independent supervision, action authority, or reusable
  server API is useful here. Daemon state and runtime authority remain in
  `AllbertAssist.Runtime.Attach.TUISession`.
  """

  alias AllbertAssist.Channels.TUI.InputDriver
  alias AllbertAssist.Runtime.Attach
  alias AllbertAssist.Runtime.Attach.TUIProtocol
  alias AllbertAssist.Security.Redactor

  @alternate_enter "\e[?1049h"
  @alternate_leave "\e[0m\e[?25h\e[?1049l"
  @render_line_limit 256
  @render_byte_limit 48 * 1_024
  @confirmation_limit 32
  @pressure_timeout_ms 1_000
  @detach_timeout_ms 2_000
  @resize_poll_ms 250
  @signal_names [:sigterm, :sighup]
  @interruptible_render_states [:thinking, :streaming, :confirming, :coding]

  @type callbacks :: map()

  @doc "Run one terminal attachment, with at most one attended reconciliation attach."
  @spec run(keyword()) :: :ok | {:error, term()}
  def run(opts \\ []) when is_list(opts) do
    callbacks = callbacks(opts)
    profile = Keyword.get(opts, :profile, "default")
    reconnects = Keyword.get(opts, :reconnect_attempts, 1)

    run_attempt(profile, %{}, reconnects, callbacks)
  end

  defp run_attempt(profile, receipts, reconnects, callbacks) do
    with {:ok, terminal} <- call0(callbacks.terminal_info),
         {:ok, socket, snapshot, flow} <- callbacks.open.(profile, terminal) do
      case terminal_session(socket, snapshot, flow, profile, terminal, receipts, callbacks) do
        {:ok, _remaining_receipts} ->
          :ok

        {:error, reason, remaining_receipts} ->
          maybe_reconcile(profile, reason, remaining_receipts, reconnects, callbacks)
      end
    else
      {:error, reason} -> attempt_open_error(reason, receipts)
      other -> attempt_open_error({:invalid_open_result, other}, receipts)
    end
  end

  defp attempt_open_error(reason, receipts) when map_size(receipts) == 0,
    do: {:error, reason}

  defp attempt_open_error(reason, receipts),
    do: {:error, {:ambiguous_close, {:reconnect_failed, reason}, map_size(receipts)}}

  defp maybe_reconcile(_profile, reason, receipts, _reconnects, _callbacks)
       when map_size(receipts) == 0,
       do: {:error, reason}

  defp maybe_reconcile(profile, reason, receipts, reconnects, callbacks)
       when reconnects > 0 do
    case callbacks.reconnect.(reason, map_size(receipts)) do
      true -> run_attempt(profile, receipts, reconnects - 1, callbacks)
      _declined -> {:error, {:ambiguous_close, reason, map_size(receipts)}}
    end
  end

  defp maybe_reconcile(_profile, reason, receipts, _reconnects, _callbacks),
    do: {:error, {:ambiguous_close, reason, map_size(receipts)}}

  defp terminal_session(socket, snapshot, flow, profile, terminal, receipts, callbacks) do
    owner = self()

    case callbacks.install_signals.(owner) do
      {:ok, signal_token} ->
        try do
          terminal_lifecycle(
            socket,
            snapshot,
            flow,
            profile,
            terminal,
            receipts,
            callbacks
          )
        after
          callbacks.uninstall_signals.(signal_token)
          callbacks.close.(socket)
        end

      {:error, reason} ->
        callbacks.close.(socket)
        {:error, {:signal_setup_failed, reason}, receipts}
    end
  end

  defp terminal_lifecycle(socket, snapshot, flow, profile, terminal, receipts, callbacks) do
    try do
      enter_result = call0(callbacks.enter_terminal)

      with :ok <- normalize_ok(enter_result),
           {:ok, driver} when is_pid(driver) <- callbacks.start_input.(self(), terminal) do
        driver_ref = Process.monitor(driver)

        try do
          case call0(callbacks.start_resize_poll) do
            {:error, reason} ->
              {:error, {:terminal_setup_failed, {:resize_poll_failed, reason}}, receipts}

            resize_token ->
              try do
                state =
                  initial_state(
                    socket,
                    snapshot,
                    flow,
                    profile,
                    terminal,
                    receipts,
                    {driver, driver_ref},
                    callbacks
                  )

                case initialize_session(state) do
                  {:ok, state} -> loop(state)
                  {:stop, reason, state} -> {:error, reason, state.receipts}
                end
              after
                callbacks.stop_resize_poll.(resize_token)
              end
          end
        after
          callbacks.stop_input.(driver)
          Process.demonitor(driver_ref, [:flush])
        end
      else
        {:error, reason} -> {:error, {:terminal_setup_failed, reason}, receipts}
        other -> {:error, {:terminal_setup_failed, other}, receipts}
      end
    after
      callbacks.restore_terminal.()
    end
  end

  defp initial_state(
         socket,
         snapshot,
         flow,
         profile,
         terminal,
         receipts,
         {driver, driver_ref},
         callbacks
       ) do
    receipt_bytes = receipt_bytes(receipts)

    %{
      socket: socket,
      flow: flow,
      profile: profile,
      terminal: terminal,
      driver: driver,
      driver_ref: driver_ref,
      callbacks: callbacks,
      render_revision: snapshot.payload.render_revision,
      render_state: snapshot.payload.state,
      render_lines: bounded_terminal_lines(snapshot.payload.lines),
      live_lines: [],
      status_text:
        if(snapshot.payload.gap?, do: "Presentation resumed from a full snapshot.", else: ""),
      confirmations: %{},
      receipts: receipts,
      receipt_bytes: receipt_bytes,
      next_receipt_order: next_receipt_order(receipts),
      outbound: :queue.new(),
      outbound_frames: 0,
      outbound_bytes: 0,
      pressure: nil,
      closing?: false,
      replay?: map_size(receipts) > 0,
      capacity_paused?: false
    }
  end

  defp initialize_session(state) do
    with :ok <-
           state.callbacks.setopts.(state.socket,
             packet_size: TUIProtocol.limits().frame_body_bytes,
             send_timeout: 5_000,
             send_timeout_close: true,
             active: false
           ),
         {:ok, state} <- render_initial(state),
         {:ok, state} <- enqueue_ack(state),
         {:ok, state} <- drain_outbound(state),
         {:ok, state} <- enqueue_replays(state),
         {:ok, state} <- drain_outbound(state),
         :ok <- rearm(state),
         {:ok, state} <- maybe_prompt(state) do
      {:ok, state}
    else
      {:stop, reason, state} -> {:stop, reason, state}
      {:error, reason, state} -> {:stop, reason, state}
      {:error, reason} -> {:stop, reason, state}
    end
  end

  defp loop(state) do
    receive do
      {:tcp, socket, payload} when socket == state.socket ->
        state
        |> receive_daemon_frame(payload)
        |> continue_or_stop()

      {:tcp_closed, socket} when socket == state.socket ->
        {:error, :daemon_connection_closed, state.receipts}

      {:tcp_error, socket, reason} when socket == state.socket ->
        {:error, {:daemon_connection_error, reason}, state.receipts}

      {:tui_input_line, driver, line} when driver == state.driver ->
        state
        |> handle_input_line(line)
        |> continue_or_stop()

      {:tui_input_escape, driver} when driver == state.driver ->
        state
        |> send_control(:cancel, %{reason: :operator_escape})
        |> continue_or_stop()

      {:tui_input_quit, driver, :ctrl_c} when driver == state.driver ->
        state
        |> interrupt_and_detach()
        |> continue_or_stop()

      {:tui_input_quit, driver, :ctrl_d} when driver == state.driver ->
        state
        |> send_detach(:eof)
        |> continue_or_stop()

      {:tui_signal, signal} when signal in @signal_names ->
        state
        |> send_detach(:operator_exit)
        |> continue_or_stop()

      :tui_resize_poll ->
        state
        |> maybe_resize()
        |> continue_or_stop()

      {:tui_pressure_timeout, marker} ->
        pressure_timeout(state, marker)
        |> continue_or_stop()

      {:tui_detach_timeout, marker} ->
        detach_timeout(state, marker)
        |> continue_or_stop()

      {:DOWN, ref, :process, driver, reason}
      when ref == state.driver_ref and driver == state.driver ->
        {:error, {:input_driver_stopped, reason}, state.receipts}

      _other ->
        loop(state)
    end
  end

  defp continue_or_stop({:ok, state}), do: loop(state)
  defp continue_or_stop({:stop, :normal, state}), do: {:ok, state.receipts}
  defp continue_or_stop({:stop, reason, state}), do: {:error, reason, state.receipts}
  defp continue_or_stop({:error, reason, state}), do: {:error, reason, state.receipts}

  defp receive_daemon_frame(state, payload) do
    opts = [max_text_bytes: TUIProtocol.limits().maximum_max_text_bytes]

    with {:ok, frame} <- TUIProtocol.decode_frame(payload, :daemon_to_client, opts),
         {:ok, candidate_flow} <-
           TUIProtocol.accept_frame(state.flow, :daemon_to_client, frame, opts),
         {:ok, rendered} <- apply_daemon_frame(%{state | flow: candidate_flow}, frame),
         {:ok, rendered} <- acknowledge_after_render(rendered, frame),
         {:ok, rendered} <- drain_outbound(rendered) do
      finish_daemon_frame(rendered, frame)
    else
      {:stop, reason, failed} -> {:stop, reason, failed}
      {:error, reason, failed} -> {:stop, reason, failed}
      {:error, reason} -> {:stop, {:protocol_receive_failed, reason}, state}
    end
  end

  defp finish_daemon_frame(state, %{frame: :close, payload: payload}),
    do: classify_daemon_close(state, payload)

  defp finish_daemon_frame(state, _frame) do
    case rearm(state) do
      :ok -> resume_after_daemon_frame(state)
      {:error, reason} -> {:stop, {:socket_rearm_failed, reason}, state}
    end
  end

  defp resume_after_daemon_frame(state) do
    state = maybe_resume_input(state)

    if state.capacity_paused? and input_capacity_available?(state) do
      maybe_prompt(state)
    else
      {:ok, state}
    end
  end

  defp apply_daemon_frame(state, %{frame: :snapshot, payload: payload}) do
    state = %{
      state
      | render_revision: payload.render_revision,
        render_state: payload.state,
        render_lines: bounded_terminal_lines(payload.lines),
        live_lines: [],
        status_text: if(payload.gap?, do: "Presentation resumed from a full snapshot.", else: "")
    }

    with {:ok, state} <-
           write_static(state, ["-- daemon presentation snapshot --" | state.render_lines]) do
      render_live(state)
    end
  end

  defp apply_daemon_frame(state, %{frame: :delta, payload: payload}) do
    state = apply_delta(state, payload)

    case payload.mode do
      :append ->
        with {:ok, state} <- write_static(state, payload.lines), do: render_live(state)

      _replace_or_clear ->
        render_live(state)
    end
  end

  defp apply_daemon_frame(state, %{frame: :status, payload: payload}) do
    state = %{
      state
      | render_revision: payload.render_revision,
        render_state: payload.state,
        status_text: payload.text
    }

    render_live(state)
  end

  defp apply_daemon_frame(state, %{frame: :confirmation, payload: payload}) do
    confirmations = Map.put(state.confirmations, payload.confirmation_id, payload)
    candidate = %{state | confirmations: confirmations, render_state: :confirming}

    if map_size(confirmations) <= @confirmation_limit do
      render_live(candidate)
    else
      {:error, :client_confirmation_capacity, candidate}
    end
  end

  defp apply_daemon_frame(state, %{frame: :completion, payload: payload}) do
    candidate =
      state
      |> Map.put(:status_text, "Input #{payload.outcome}.")
      |> Map.put(:render_state, :idle)
      |> Map.update!(:render_lines, &bounded_terminal_lines(&1 ++ payload.lines))

    with {:ok, rendered} <- write_static(candidate, payload.lines),
         {:ok, rendered} <- render_live(rendered) do
      {:ok, release_receipt(rendered, payload.input_receipt_id)}
    end
  end

  defp apply_daemon_frame(state, %{frame: :error, payload: payload}) do
    candidate =
      state
      |> Map.put(:status_text, payload.message)
      |> Map.put(:render_state, :error)

    with {:ok, rendered} <- render_live(candidate) do
      {:ok, release_optional_receipt(rendered, payload.input_receipt_id)}
    end
  end

  defp apply_daemon_frame(state, %{frame: :close, payload: payload}) do
    render_live(%{state | status_text: payload.message, closing?: true})
  end

  defp apply_daemon_frame(state, %{frame: :ack}), do: {:ok, state}

  defp apply_delta(state, %{mode: :append} = payload) do
    %{
      state
      | render_revision: payload.render_revision,
        render_lines: bounded_terminal_lines(state.render_lines ++ payload.lines),
        live_lines: [],
        render_state: :streaming
    }
  end

  defp apply_delta(state, %{mode: :replace_live} = payload) do
    %{
      state
      | render_revision: payload.render_revision,
        live_lines: bounded_terminal_lines(payload.lines),
        render_state: :streaming
    }
  end

  defp apply_delta(state, %{mode: :clear_live} = payload) do
    %{state | render_revision: payload.render_revision, live_lines: []}
  end

  defp render_initial(state) do
    with {:ok, state} <-
           write_static(state, ["Allbert TUI - daemon attached" | state.render_lines]) do
      render_live(state)
    end
  end

  defp write_static(state, []), do: {:ok, state}

  defp write_static(state, lines) do
    lines = bounded_terminal_lines(lines)

    case state.callbacks.write_input.(state.driver, Enum.intersperse(lines, "\n")) do
      :ok -> {:ok, state}
      {:error, reason} -> {:error, {:terminal_render_failed, reason}, state}
      other -> {:error, {:terminal_render_failed, other}, state}
    end
  end

  defp render_live(state) do
    with {:ok, lines} <- live_display_lines(state) do
      case state.callbacks.write_live.(state.driver, state.terminal.columns, lines) do
        :ok -> {:ok, state}
        {:error, reason} -> {:error, {:terminal_render_failed, reason}, state}
        other -> {:error, {:terminal_render_failed, other}, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp acknowledge_after_render(state, %{frame: :close}), do: {:ok, state}
  defp acknowledge_after_render(state, %{frame: :ack}), do: {:ok, state}
  defp acknowledge_after_render(state, _frame), do: enqueue_ack(state)

  defp classify_daemon_close(state, %{code: code, message: message}) do
    cond do
      code in [:normal, :client_detach] and map_size(state.receipts) == 0 ->
        {:stop, :normal, state}

      map_size(state.receipts) > 0 ->
        {:stop, {:daemon_closed, code, message}, state}

      true ->
        {:stop, {:daemon_closed, code, message}, state}
    end
  end

  defp handle_input_line(state, line) do
    line = to_string(line)
    normalized = String.trim(line)

    cond do
      normalized == "" ->
        maybe_prompt(state)

      normalized in ["/quit", "/exit"] ->
        send_detach(state, :operator_exit)

      true ->
        case typed_confirmation_decision(line) do
          {:ok, decision, confirmation_id} ->
            send_confirmation(state, confirmation_id, decision)

          :ordinary_input ->
            send_input(state, normalized)
        end
    end
  end

  defp typed_confirmation_decision("ALLBERT:APPROVE:" <> confirmation_id)
       when byte_size(confirmation_id) > 0,
       do: {:ok, :approve, confirmation_id}

  defp typed_confirmation_decision("ALLBERT:DENY:" <> confirmation_id)
       when byte_size(confirmation_id) > 0,
       do: {:ok, :deny, confirmation_id}

  defp typed_confirmation_decision(_line), do: :ordinary_input

  defp send_confirmation(state, confirmation_id, decision) do
    if Map.has_key?(state.confirmations, confirmation_id) do
      with {:ok, state} <-
             enqueue_frame(state, :confirmation, %{
               confirmation_id: confirmation_id,
               decision: decision
             }),
           {:ok, state} <- drain_outbound(state),
           {:ok, state} <- maybe_prompt(state) do
        {:ok, state}
      end
    else
      state = %{
        state
        | status_text: "That confirmation id was not issued by this daemon session."
      }

      with {:ok, state} <- render_live(state), do: maybe_prompt(state)
    end
  end

  defp send_input(state, text) do
    max_bytes = TUIProtocol.limits().maximum_max_text_bytes

    with {:ok, normalized} <- TUIProtocol.normalize_input(text, max_bytes),
         receipt_id <- TUIProtocol.new_receipt_id(),
         {:ok, state} <- retain_receipt(state, receipt_id, normalized) do
      enqueue_input(state, receipt_id, normalized)
    else
      {:error, reason, state} ->
        input_rejected(state, reason)

      {:error, reason} ->
        input_rejected(state, reason)
    end
  end

  defp enqueue_input(state, receipt_id, normalized) do
    with {:ok, queued} <-
           enqueue_frame(state, :input, %{input_receipt_id: receipt_id, text: normalized}),
         {:ok, sent} <- drain_outbound(queued) do
      maybe_prompt(sent)
    else
      {:error, reason, unsent} ->
        input_rejected(release_receipt(unsent, receipt_id), reason)

      stopped ->
        stopped
    end
  end

  defp input_rejected(state, reason) do
    state = %{state | status_text: input_failure_message(reason)}
    with {:ok, state} <- render_live(state), do: maybe_prompt(state)
  end

  defp input_failure_message(:invalid_input),
    do: "Input is empty, invalid, or above the 32,000-byte protocol ceiling."

  defp input_failure_message(:receipt_capacity),
    do: "Input is paused until pending receipts finish."

  defp input_failure_message(:outbound_capacity), do: "Input is paused by transport backpressure."
  defp input_failure_message(reason), do: "Input was not sent: #{inspect(reason)}"

  defp retain_receipt(state, receipt_id, text) do
    limits = TUIProtocol.limits().client_unacknowledged

    with {:ok, bytes} <- input_frame_bytes(receipt_id, text) do
      if map_size(state.receipts) < limits.frames and
           state.receipt_bytes + bytes <= limits.bytes do
        receipt = %{text: text, bytes: bytes, order: state.next_receipt_order}

        {:ok,
         %{
           state
           | receipts: Map.put(state.receipts, receipt_id, receipt),
             receipt_bytes: state.receipt_bytes + bytes,
             next_receipt_order: state.next_receipt_order + 1
         }}
      else
        state.callbacks.pause_input.(state.driver)
        {:error, :receipt_capacity, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp release_receipt(state, receipt_id) do
    case Map.pop(state.receipts, receipt_id) do
      {nil, _receipts} ->
        state

      {%{bytes: bytes}, receipts} ->
        %{state | receipts: receipts, receipt_bytes: max(0, state.receipt_bytes - bytes)}
    end
  end

  defp release_optional_receipt(state, nil), do: state
  defp release_optional_receipt(state, receipt_id), do: release_receipt(state, receipt_id)

  defp enqueue_replays(%{replay?: false} = state), do: {:ok, state}

  defp enqueue_replays(state) do
    state.receipts
    |> Enum.sort_by(fn {_receipt_id, receipt} -> receipt.order end)
    |> Enum.reduce_while({:ok, %{state | replay?: false}}, fn {receipt_id, receipt},
                                                              {:ok, current} ->
      with {:ok, queued} <-
             enqueue_frame(current, :input, %{
               input_receipt_id: receipt_id,
               text: receipt.text
             }),
           {:ok, sent} <- drain_outbound(queued) do
        {:cont, {:ok, sent}}
      else
        {:error, reason, failed} -> {:halt, {:error, reason, failed}}
        {:stop, reason, failed} -> {:halt, {:stop, reason, failed}}
      end
    end)
  end

  defp enqueue_ack(state), do: enqueue_frame(state, :ack, %{})

  defp enqueue_frame(state, frame, payload) do
    limits = TUIProtocol.limits().client_outbound_unsent
    state = if frame == :resize, do: drop_queued_resize(state), else: state

    with {:ok, entry_bytes} <- frame_bytes(frame, payload) do
      if state.outbound_frames < limits.frames and
           state.outbound_bytes + entry_bytes <= limits.bytes do
        entry = %{frame: frame, payload: payload, bytes: entry_bytes}

        {:ok,
         %{
           state
           | outbound: :queue.in(entry, state.outbound),
             outbound_frames: state.outbound_frames + 1,
             outbound_bytes: state.outbound_bytes + entry_bytes
         }}
      else
        state.callbacks.pause_input.(state.driver)
        {:error, :outbound_capacity, state}
      end
    else
      {:error, reason} -> {:error, reason, state}
    end
  rescue
    _error -> {:error, :outbound_capacity, state}
  end

  defp frame_bytes(frame, payload) do
    TUIProtocol.encoded_frame_upper_bound(
      :client_to_daemon,
      frame,
      payload,
      max_text_bytes: TUIProtocol.limits().maximum_max_text_bytes
    )
  end

  defp input_frame_bytes(receipt_id, text),
    do: frame_bytes(:input, %{input_receipt_id: receipt_id, text: text})

  defp drop_queued_resize(state) do
    entries = state.outbound |> :queue.to_list() |> Enum.reject(&(&1.frame == :resize))
    put_outbound(state, entries)
  end

  defp put_outbound(state, entries) do
    %{
      state
      | outbound: :queue.from_list(entries),
        outbound_frames: length(entries),
        outbound_bytes: Enum.sum(Enum.map(entries, & &1.bytes))
    }
  end

  defp drain_outbound(state) do
    case :queue.out(state.outbound) do
      {:empty, _queue} ->
        finish_pressure(state)

      {{:value, entry}, rest} ->
        deliver_outbound(state, entry, rest)
    end
  end

  defp deliver_outbound(state, entry, rest) do
    opts = [max_text_bytes: TUIProtocol.limits().maximum_max_text_bytes]

    case TUIProtocol.send_frame(
           state.flow,
           :client_to_daemon,
           entry.frame,
           entry.payload,
           opts
         ) do
      {:ok, envelope, next_flow} ->
        transmit_outbound(state, entry, rest, envelope, next_flow)

      {:error, :overflow} ->
        outbound_overflow(state, entry)

      {:error, reason} ->
        {:stop, {:protocol_send_failed, reason}, state}
    end
  end

  defp transmit_outbound(state, entry, rest, envelope, next_flow) do
    case state.callbacks.send.(state.socket, :erlang.term_to_binary(envelope)) do
      :ok ->
        state
        |> Map.put(:flow, next_flow)
        |> mark_frame_sent(entry)
        |> put_outbound(:queue.to_list(rest))
        |> drain_outbound()

      {:error, reason} ->
        {:stop, {:socket_send_failed, reason}, state}

      other ->
        {:stop, {:socket_send_failed, other}, state}
    end
  end

  defp outbound_overflow(state, entry) do
    if control_frame?(entry.frame) do
      {:stop, {:control_not_delivered, :overflow}, state}
    else
      state
      |> enter_pressure()
      |> render_live()
    end
  end

  defp enter_pressure(%{pressure: nil} = state) do
    marker = make_ref()
    timer = Process.send_after(self(), {:tui_pressure_timeout, marker}, @pressure_timeout_ms)
    state.callbacks.pause_input.(state.driver)

    state
    |> Map.put(:pressure, {marker, timer})
    |> Map.put(:status_text, "Transport backpressure: terminal input is paused.")
  end

  defp enter_pressure(state), do: state

  defp clear_pressure(%{pressure: nil} = state), do: maybe_resume_input(state)

  defp clear_pressure(%{pressure: {_marker, timer}} = state) do
    _ = Process.cancel_timer(timer)
    state.callbacks.resume_input.(state.driver)
    %{state | pressure: nil}
  end

  defp finish_pressure(%{pressure: nil} = state), do: {:ok, maybe_resume_input(state)}

  defp finish_pressure(state) do
    state =
      state
      |> clear_pressure()
      |> Map.put(:status_text, "Transport backpressure cleared.")

    with {:ok, state} <- render_live(state), do: maybe_prompt(state)
  end

  defp maybe_resume_input(state) do
    if input_capacity_available?(state) and is_nil(state.pressure) do
      state.callbacks.resume_input.(state.driver)
    end

    state
  end

  defp input_capacity_available?(state) do
    limits = TUIProtocol.limits().client_unacknowledged

    case maximum_input_frame_bytes() do
      {:ok, reserve} ->
        map_size(state.receipts) < limits.frames and
          state.receipt_bytes <= limits.bytes - reserve

      {:error, _reason} ->
        false
    end
  end

  defp maximum_input_frame_bytes do
    receipt_id = String.duplicate("A", 22)
    text = String.duplicate("x", TUIProtocol.limits().maximum_max_text_bytes)
    input_frame_bytes(receipt_id, text)
  end

  defp send_control(state, frame, payload) do
    # Control is sequenced ahead of unsent input/confirmation without dropping
    # their custody. Existing controls keep their order, so Ctrl-C remains
    # cancel-then-detach. If the leading control cannot enter the frozen peer
    # window, close locally rather than pretending it was delivered.
    with {:ok, state} <- enqueue_control(state, frame, payload),
         {:ok, state} <- drain_outbound(state) do
      {:ok, state}
    else
      {:error, reason, failed} -> {:stop, {:control_not_delivered, reason}, failed}
      {:stop, reason, failed} -> {:stop, reason, failed}
    end
  end

  defp enqueue_control(state, frame, payload) do
    with {:ok, state} <- enqueue_frame(state, frame, payload) do
      entries = :queue.to_list(state.outbound)
      {entry, entries} = List.pop_at(entries, -1)
      {controls, retained} = Enum.split_while(entries, &control_frame?(&1.frame))
      {:ok, put_outbound(state, controls ++ [entry] ++ retained)}
    end
  end

  defp control_frame?(frame), do: frame in [:cancel, :detach]

  defp mark_frame_sent(state, %{frame: :confirmation, payload: payload}) do
    %{state | confirmations: Map.delete(state.confirmations, payload.confirmation_id)}
  end

  defp mark_frame_sent(state, _entry), do: state

  defp interrupt_and_detach(%{render_state: render_state, receipts: receipts} = state)
       when render_state in @interruptible_render_states or map_size(receipts) > 0 do
    with {:ok, state} <- send_control(state, :cancel, %{reason: :operator_interrupt}) do
      send_detach(state, :operator_exit)
    end
  end

  defp interrupt_and_detach(state), do: send_detach(state, :operator_exit)

  defp send_detach(%{closing?: true} = state, _reason), do: {:ok, state}

  defp send_detach(state, reason) do
    case send_control(state, :detach, %{reason: reason}) do
      {:ok, state} ->
        marker = make_ref()
        _timer = Process.send_after(self(), {:tui_detach_timeout, marker}, @detach_timeout_ms)
        {:ok, %{state | closing?: {:waiting, marker}}}

      other ->
        other
    end
  end

  defp pressure_timeout(%{pressure: {marker, _timer}} = state, marker),
    do: {:stop, :client_backpressure_timeout, state}

  defp pressure_timeout(state, _marker), do: {:ok, state}

  defp detach_timeout(%{closing?: {:waiting, marker}} = state, marker),
    do: {:stop, :daemon_detach_timeout, state}

  defp detach_timeout(state, _marker), do: {:ok, state}

  defp maybe_resize(state) do
    case state.callbacks.dimensions.() do
      {:ok, %{columns: columns, rows: rows} = dimensions}
      when columns != state.terminal.columns or rows != state.terminal.rows ->
        state = %{state | terminal: Map.merge(state.terminal, dimensions)}

        with {:ok, state} <- enqueue_frame(state, :resize, dimensions),
             {:ok, state} <- drain_outbound(state),
             {:ok, state} <- render_live(state) do
          {:ok, state}
        end

      _unchanged_or_unavailable ->
        {:ok, state}
    end
  end

  defp maybe_prompt(%{closing?: closing?} = state) when closing? != false, do: {:ok, state}
  defp maybe_prompt(%{pressure: pressure} = state) when not is_nil(pressure), do: {:ok, state}

  defp maybe_prompt(state) do
    if input_capacity_available?(state) do
      state.callbacks.prompt_input.(state.driver, "allbert> ")
      {:ok, %{state | capacity_paused?: false}}
    else
      state.callbacks.pause_input.(state.driver)

      state = %{
        state
        | capacity_paused?: true,
          status_text: "Input custody is full; terminal input is paused until a receipt finishes."
      }

      render_live(state)
    end
  end

  defp rearm(state), do: state.callbacks.setopts.(state.socket, active: :once)

  defp live_display_lines(state) do
    status_lines =
      if state.status_text == "",
        do: [],
        else:
          state.status_text
          |> terminal_lines()
          |> Enum.map(&"[#{state.render_state}] #{&1}")

    with {:ok, confirmation_lines} <- confirmation_lines(state.confirmations) do
      required = status_lines ++ confirmation_lines
      required_bytes = display_bytes(required)

      if length(required) <= @render_line_limit and required_bytes <= @render_byte_limit do
        presentation = bounded_terminal_lines(state.live_lines)

        presentation =
          bounded_lines_to(
            presentation,
            @render_line_limit - length(required),
            @render_byte_limit - required_bytes
          )

        {:ok, presentation ++ required}
      else
        {:error, :client_confirmation_capacity}
      end
    end
  end

  defp confirmation_lines(confirmations) do
    confirmations
    |> Map.values()
    |> Enum.sort_by(& &1.confirmation_id)
    |> Enum.reduce_while({:ok, []}, fn confirmation, {:ok, lines} ->
      if representable_confirmation_id?(confirmation.confirmation_id) do
        id = terminal_text(confirmation.confirmation_id)

        {:cont,
         {:ok,
          lines ++
            terminal_lines(confirmation.prompt) ++
            ["Type ALLBERT:APPROVE:#{id} or ALLBERT:DENY:#{id}."]}}
      else
        {:halt, {:error, :unrepresentable_confirmation_id}}
      end
    end)
  end

  defp representable_confirmation_id?(id) when is_binary(id) do
    String.valid?(id) and
      Enum.all?(:unicode.characters_to_list(id), fn codepoint ->
        not terminal_control?(codepoint)
      end)
  rescue
    _error -> false
  end

  defp representable_confirmation_id?(_id), do: false

  defp terminal_text(value) do
    value
    |> to_string()
    |> String.to_charlist()
    |> Enum.map(fn codepoint ->
      if terminal_control?(codepoint), do: 0xFFFD, else: codepoint
    end)
    |> List.to_string()
  end

  defp terminal_lines(value) do
    value
    |> to_string()
    |> String.replace("\r\n", "\n")
    |> String.split("\n", trim: false)
    |> Enum.map(&terminal_text/1)
  end

  defp terminal_control?(codepoint),
    do: codepoint in 0..31 or codepoint in 127..159

  defp display_bytes(lines),
    do: Enum.reduce(lines, 0, fn line, bytes -> bytes + byte_size(line) + 2 end)

  defp bounded_lines(lines) do
    bounded_lines_to(lines, @render_line_limit, @render_byte_limit)
  end

  defp bounded_terminal_lines(lines) do
    lines
    |> Enum.flat_map(&terminal_lines/1)
    |> bounded_lines()
  end

  defp bounded_lines_to(_lines, max_count, max_bytes) when max_count <= 0 or max_bytes <= 0,
    do: []

  defp bounded_lines_to(lines, max_count, max_bytes) do
    {kept, _bytes, _count} =
      lines
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0, 0}, fn line, {kept, bytes, count} ->
        line = to_string(line)
        line_bytes = byte_size(line)

        encoded_bytes = line_bytes + 2

        if count < max_count and bytes + encoded_bytes <= max_bytes do
          {:cont, {[line | kept], bytes + encoded_bytes, count + 1}}
        else
          {:halt, {kept, bytes, count}}
        end
      end)

    kept
  end

  defp receipt_bytes(receipts),
    do: receipts |> Map.values() |> Enum.map(& &1.bytes) |> Enum.sum()

  defp next_receipt_order(receipts) do
    receipts
    |> Map.values()
    |> Enum.map(& &1.order)
    |> Enum.max(fn -> 0 end)
    |> Kernel.+(1)
  end

  defp callbacks(opts) do
    output = Keyword.get(opts, :output_fun, &default_output/1)

    defaults = %{
      terminal_info: &terminal_info/0,
      dimensions: &dimensions/0,
      open: &Attach.open_tui_session/2,
      setopts: &:inet.setopts/2,
      send: &:gen_tcp.send/2,
      close: &:gen_tcp.close/1,
      enter_terminal: fn -> normalize_output(output.(@alternate_enter)) end,
      restore_terminal: fn ->
        restore_cooked()
        _ = output.(@alternate_leave)
        :ok
      end,
      install_signals: &install_signals/1,
      uninstall_signals: &uninstall_signals/1,
      start_resize_poll: fn -> :timer.send_interval(@resize_poll_ms, :tui_resize_poll) end,
      stop_resize_poll: &stop_resize_poll/1,
      start_input: fn owner, terminal ->
        InputDriver.start(owner,
          output_fun: output,
          live_region?: true,
          single_submission?: true,
          terminal_columns: terminal.columns,
          max_buffer_bytes: TUIProtocol.limits().maximum_max_text_bytes
        )
      end,
      stop_input: &stop_input/1,
      prompt_input: &InputDriver.prompt/2,
      write_input: &InputDriver.write/2,
      write_live: &InputDriver.update_live/3,
      pause_input: &InputDriver.pause/1,
      resume_input: &InputDriver.resume/1,
      reconnect: &ask_reconnect/2
    }

    Map.merge(defaults, Keyword.get(opts, :callbacks, %{}))
  end

  defp terminal_info do
    if tty?(:stdin) and tty?(:stdout) do
      with {:ok, dimensions} <- dimensions() do
        {:ok,
         Map.merge(dimensions, %{
           color: terminal_color(),
           unicode?: unicode_terminal?()
         })}
      end
    else
      {:error, :no_tty}
    end
  end

  defp dimensions do
    with {:ok, columns} <- terminal_measure(:columns, "COLUMNS", 80, 1, 500),
         {:ok, rows} <- terminal_measure(:rows, "LINES", 24, 1, 200) do
      {:ok, %{columns: columns, rows: rows}}
    end
  end

  defp terminal_measure(kind, env, fallback, minimum, maximum) do
    measured = if kind == :columns, do: :io.columns(), else: :io.rows()

    value =
      case measured do
        {:ok, integer} when is_integer(integer) -> integer
        _unavailable -> parse_integer(System.get_env(env), fallback)
      end

    {:ok, value |> max(minimum) |> min(maximum)}
  rescue
    _error -> {:ok, fallback}
  end

  defp parse_integer(nil, fallback), do: fallback

  defp parse_integer(value, fallback) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _invalid -> fallback
    end
  end

  defp tty?(stream) do
    function_exported?(:prim_tty, :isatty, 1) and :prim_tty.isatty(stream) == true
  rescue
    _error -> false
  end

  defp terminal_color do
    term = System.get_env("TERM", "") |> String.downcase()
    color_term = System.get_env("COLORTERM", "") |> String.downcase()

    cond do
      term == "dumb" -> :none
      color_term in ["truecolor", "24bit"] -> :truecolor
      String.contains?(term, "256color") -> :ansi256
      true -> :ansi16
    end
  end

  defp unicode_terminal? do
    locale =
      System.get_env("LC_ALL") || System.get_env("LC_CTYPE") || System.get_env("LANG") || ""

    locale = String.downcase(locale)
    String.contains?(locale, "utf-8") or String.contains?(locale, "utf8")
  end

  defp install_signals(owner), do: install_signals(@signal_names, owner, [])

  defp install_signals([], _owner, installed), do: {:ok, installed}

  defp install_signals([signal | remaining], owner, installed) do
    id = make_ref()

    result =
      try do
        System.trap_signal(signal, id, fn ->
          send(owner, {:tui_signal, signal})
          :ok
        end)
      rescue
        error -> {:error, {error.__struct__, Exception.message(error)}}
      catch
        kind, reason -> {:error, {kind, reason}}
      end

    case result do
      {:ok, ^id} ->
        install_signals(remaining, owner, [{signal, id} | installed])

      {:error, :not_sup} ->
        install_signals(remaining, owner, installed)

      {:error, reason} ->
        uninstall_signals(installed)
        {:error, {signal, reason}}
    end
  end

  defp uninstall_signals(installed) when is_list(installed) do
    Enum.each(installed, fn {signal, id} ->
      _ = System.untrap_signal(signal, id)
    end)

    :ok
  rescue
    _error -> :ok
  end

  defp uninstall_signals(_invalid), do: :ok

  defp stop_resize_poll({:ok, timer}) do
    _ = :timer.cancel(timer)
    :ok
  end

  defp stop_resize_poll(_other), do: :ok

  defp stop_input(driver) when is_pid(driver) do
    if Process.alive?(driver), do: GenServer.stop(driver, :normal, 1_000)
    :ok
  catch
    :exit, _reason -> :ok
  end

  defp stop_input(_driver), do: :ok

  defp restore_cooked do
    _ = :shell.start_interactive({:noshell, :cooked})
    :ok
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp ask_reconnect(reason, pending) do
    reason =
      reason
      |> Redactor.redact()
      |> inspect(limit: 20, printable_limit: 512)
      |> String.replace(~r/[\r\n]+/u, " ")

    IO.puts(
      "The daemon connection closed with #{pending} unresolved input receipt(s): " <>
        reason
    )

    case IO.gets("Reconnect once to reconcile them without creating new receipts? [y/N] ") do
      answer when is_binary(answer) -> String.downcase(String.trim(answer)) in ["y", "yes"]
      _eof -> false
    end
  end

  defp default_output(chardata), do: IO.write(chardata)

  defp normalize_output({:error, reason}), do: {:error, reason}
  defp normalize_output(_delivered), do: :ok

  defp normalize_ok(:ok), do: :ok
  defp normalize_ok({:error, reason}), do: {:error, reason}
  defp normalize_ok(other), do: {:error, other}

  defp call0(fun) do
    fun.()
  rescue
    error -> {:error, {error.__struct__, Exception.message(error)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end
end
