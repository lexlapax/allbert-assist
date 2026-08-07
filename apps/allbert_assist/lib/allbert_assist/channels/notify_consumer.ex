defmodule AllbertAssist.Channels.NotifyConsumer do
  @moduledoc """
  Signal-driven wakeup and durable completion-outbox recovery for ADR 0084.

  Signals provide low-latency delivery, but the pending fan-out parent and
  notification ledger remain authoritative. The consumer monitors SignalBus,
  re-subscribes after a bus-only restart, and reconciles completion work after
  startup and every successful subscription.
  """

  use GenServer

  require Logger

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Channels.NotifyDelivery
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Runtime
  alias Jido.Signal
  alias Jido.Signal.Bus

  @signal_path "allbert.objectives.**"
  @reconnect_delay_ms 100
  @retry_delay_ms 1_000
  @reconcile_interval_ms 30_000
  @minimum_reconcile_interval_ms 1_000
  @maximum_reconcile_interval_ms 300_000
  @default_reconcile_batch_size 100
  @maximum_reconcile_batch_size 500

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      bus: Keyword.get(opts, :bus, AllbertAssist.SignalBus),
      bus_pid: nil,
      bus_monitor: nil,
      subscription_id: nil,
      reconnect_timer: nil,
      reconcile_timer: nil,
      retry_timers: %{},
      subscribe_fun: Keyword.get(opts, :subscribe_fun, &Bus.subscribe/2),
      unsubscribe_fun: Keyword.get(opts, :unsubscribe_fun, &Bus.unsubscribe/2),
      whereis_fun: Keyword.get(opts, :whereis_fun, &Bus.whereis/1),
      notify_opts: Keyword.get(opts, :notify_opts, []),
      effect_guard: Keyword.get(opts, :effect_guard, EffectGuard),
      retry_delay_ms: Keyword.get(opts, :retry_delay_ms, @retry_delay_ms),
      reconcile_interval_ms:
        bounded_reconcile_interval(Keyword.get(opts, :reconcile_interval_ms)),
      reconcile_batch_size: bounded_reconcile_batch_size(Keyword.get(opts, :reconcile_batch_size))
    }

    send(self(), :connect_signal_bus)
    {:ok, schedule_reconcile(state)}
  end

  @impl true
  def handle_info({:signal, %Signal{} = signal}, state) do
    state = safely(fn -> with_ready_epoch(state, &handle_signal(signal, state, &1)) end, state)
    {:noreply, state}
  end

  def handle_info(:reconcile_completion_outbox, state) do
    state = cancel_reconcile_timer(state)
    state = safely(fn -> with_ready_epoch(state, &reconcile_outbox(state, &1)) end, state)
    state = schedule_reconcile(state)
    {:noreply, state}
  end

  def handle_info({:retry_completion, parent_id}, state) do
    state = %{state | retry_timers: Map.delete(state.retry_timers, parent_id)}

    state =
      safely(
        fn ->
          with_ready_epoch(state, fn epoch ->
            case Objectives.get_objective(parent_id) do
              {:ok, parent} -> reconcile_parent(parent, state, epoch)
              {:error, _reason} -> state
            end
          end)
        end,
        state
      )

    {:noreply, state}
  end

  def handle_info(:connect_signal_bus, state) do
    state = %{state | reconnect_timer: nil}

    case admit_ready_epoch(state) do
      {:ok, epoch} -> {:noreply, connect_bus(state, epoch)}
      {:error, _reason} -> {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, pid, _reason},
        %{bus_monitor: monitor, bus_pid: pid} = state
      ) do
    state =
      state
      |> Map.merge(%{bus_pid: nil, bus_monitor: nil, subscription_id: nil})
      |> schedule_reconnect()

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    if state.subscription_id && state.bus_pid && Process.alive?(state.bus_pid) do
      _ = state.unsubscribe_fun.(state.bus, state.subscription_id)
    end

    :ok
  end

  defp connect_bus(%{subscription_id: id, bus_pid: pid} = state, _epoch)
       when not is_nil(id) and is_pid(pid),
       do: state

  defp connect_bus(state, epoch) do
    case validate_epoch(epoch, state) do
      :ok ->
        with {:ok, bus_pid} <- state.whereis_fun.(state.bus),
             true <- Process.alive?(bus_pid),
             :ok <- validate_epoch(epoch, state),
             {:ok, subscription_id} <- state.subscribe_fun.(state.bus, @signal_path) do
          monitor = Process.monitor(bus_pid)
          send(self(), :reconcile_completion_outbox)

          %{
            state
            | bus_pid: bus_pid,
              bus_monitor: monitor,
              subscription_id: subscription_id,
              reconnect_timer: nil
          }
        else
          {:error, :stale_epoch} -> state
          _reason -> schedule_reconnect(state)
        end

      {:error, :stale_epoch} ->
        state

      {:error, :product_not_ready} ->
        schedule_reconnect(state)
    end
  end

  defp schedule_reconnect(%{reconnect_timer: nil} = state) do
    timer = Process.send_after(self(), :connect_signal_bus, @reconnect_delay_ms)
    %{state | reconnect_timer: timer}
  end

  defp schedule_reconnect(state), do: state

  defp schedule_reconcile(%{reconcile_timer: nil} = state) do
    timer =
      Process.send_after(
        self(),
        :reconcile_completion_outbox,
        state.reconcile_interval_ms
      )

    %{state | reconcile_timer: timer}
  end

  defp schedule_reconcile(state), do: state

  defp cancel_reconcile_timer(%{reconcile_timer: nil} = state), do: state

  defp cancel_reconcile_timer(%{reconcile_timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | reconcile_timer: nil}
  end

  defp reconcile_outbox(state, epoch) do
    state.reconcile_batch_size
    |> Notify.pending_completion_work()
    |> Enum.reduce(state, &reconcile_parent(&1, &2, epoch))
  end

  defp handle_signal(
         %Signal{type: "allbert.objectives.fanout.joined", data: data},
         state,
         epoch
       ) do
    parent_id = field(data, :parent_id)

    case Objectives.get_objective(parent_id) do
      {:ok, %{fanout_role: "parent", report_delivery_state: "pending"} = parent} ->
        reconcile_parent(parent, state, epoch)

      _other ->
        state
    end
  end

  defp handle_signal(
         %Signal{type: "allbert.objectives.run.blocked", data: data, id: id},
         state,
         epoch
       ) do
    child_id = field(data, :child_id)

    with {:ok, child} <- Objectives.get_objective(child_id),
         {:ok, parent} <- Objectives.get_objective(child.parent_objective_id) do
      case Objectives.list_steps(child.id) |> List.last() do
        %{confirmation_id: confirmation_id}
        when is_binary(confirmation_id) and confirmation_id != "" ->
          body =
            "Approval needed for #{child.title}. " <>
              "Reply ALLBERT:SHOW:#{confirmation_id}, ALLBERT:APPROVE:#{confirmation_id}, or ALLBERT:DENY:#{confirmation_id}."

          if :ok == validate_epoch(epoch, state) do
            _ =
              Notify.deliver(parent, :confirmation_request, body,
                child_objective_id: child.id,
                event_key: "confirmation:#{confirmation_id}",
                allbert_pack_epoch: epoch
              )
          end

        _other ->
          status(parent, child, "blocked", id, state, epoch)
      end
    end

    state
  end

  defp handle_signal(%Signal{type: type, data: data, id: id}, state, epoch)
       when type in [
              "allbert.objectives.run.started",
              "allbert.objectives.run.progress",
              "allbert.objectives.run.completed",
              "allbert.objectives.run.failed",
              "allbert.objectives.run.cancelled"
            ] do
    child_id = field(data, :child_id)

    with {:ok, child} <- Objectives.get_objective(child_id),
         {:ok, parent} <- Objectives.get_objective(child.parent_objective_id) do
      status(
        parent,
        child,
        String.replace_prefix(type, "allbert.objectives.run.", ""),
        id,
        state,
        epoch
      )
    end

    state
  end

  defp handle_signal(_signal, state, _epoch), do: state

  defp reconcile_parent(parent, state, epoch) do
    case validate_epoch(epoch, state) do
      :ok -> reconcile_parent_when_ready(parent, state, epoch)
      {:error, _reason} -> state
    end
  end

  defp reconcile_parent_when_ready(parent, state, epoch) do
    case Notify.recover_completion(
           parent,
           Keyword.put(state.notify_opts, :allbert_pack_epoch, epoch)
         ) do
      {:ok, %NotifyDelivery{state: "delivered"}} ->
        if :ok == validate_epoch(epoch, state) do
          _ = acknowledge_report(parent, epoch)
          clear_retry(parent.id, state)
        else
          state
        end

      {:ok, %NotifyDelivery{state: "failed", attempt_count: attempts}} when attempts < 2 ->
        schedule_retry(parent.id, state)

      {:ok, _terminal_or_skipped} ->
        clear_retry(parent.id, state)

      {:error, {:audit_failed, reason, %NotifyDelivery{state: "delivered"}}} ->
        Logger.warning(
          "channel completion audit failed after durable delivery parent=#{parent.id} reason=#{inspect(reason)}"
        )

        if :ok == validate_epoch(epoch, state) do
          _ = acknowledge_report(parent, epoch)
          clear_retry(parent.id, state)
        else
          state
        end

      {:error, {:audit_failed, reason, %NotifyDelivery{state: "failed", attempt_count: attempts}}}
      when attempts < 2 ->
        Logger.warning(
          "channel completion audit failed after definitive failure parent=#{parent.id} reason=#{inspect(reason)}"
        )

        schedule_retry(parent.id, state)

      {:error, {:audit_failed, reason, %NotifyDelivery{}}} ->
        Logger.warning(
          "channel completion audit failed parent=#{parent.id} reason=#{inspect(reason)}"
        )

        clear_retry(parent.id, state)

      {:error, reason} ->
        Logger.warning(
          "channel completion recovery failed parent=#{parent.id} reason=#{inspect(reason)}"
        )

        state
    end
  end

  defp schedule_retry(parent_id, %{retry_timers: timers} = state) do
    if Map.has_key?(timers, parent_id) do
      state
    else
      timer = Process.send_after(self(), {:retry_completion, parent_id}, state.retry_delay_ms)
      %{state | retry_timers: Map.put(timers, parent_id, timer)}
    end
  end

  defp clear_retry(parent_id, %{retry_timers: timers} = state) do
    case Map.pop(timers, parent_id) do
      {nil, timers} ->
        %{state | retry_timers: timers}

      {timer, timers} ->
        Process.cancel_timer(timer)
        %{state | retry_timers: timers}
    end
  end

  defp acknowledge_report(parent, epoch) do
    Runtime.acknowledge_report_delivery(Fanout.receipt_for(:report, parent.id), %{
      user_id: parent.user_id,
      channel: parent.source_channel,
      thread_id: parent.source_thread_id,
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      origin_receiver_account_ref: parent.origin_receiver_account_ref,
      allbert_pack_epoch: epoch
    })
  end

  defp status(parent, child, status, signal_id, state, epoch) do
    if :ok == validate_epoch(epoch, state) do
      _ =
        Notify.deliver(parent, :status, "#{parent.title}: #{child.title} — #{status}",
          child_objective_id: child.id,
          event_key: signal_id || "#{child.id}:#{status}",
          allbert_pack_epoch: epoch
        )
    end

    :ok
  end

  defp safely(fun, fallback) do
    fun.()
  rescue
    exception ->
      Logger.warning("channel notify consumer failed: #{Exception.message(exception)}")
      fallback
  catch
    kind, reason ->
      Logger.warning("channel notify consumer failed: #{inspect({kind, reason})}")
      fallback
  end

  defp with_ready_epoch(state, fun) do
    case admit_ready_epoch(state) do
      {:ok, epoch} -> fun.(epoch)
      {:error, _reason} -> state
    end
  end

  defp admit_ready_epoch(state), do: effect_guard_call(state.effect_guard, :admit_ready, [])

  defp validate_epoch(epoch, state), do: effect_guard_call(state.effect_guard, :validate, [epoch])

  defp effect_guard_call({module, owner}, function, args),
    do: apply(module, function, [owner | args])

  defp effect_guard_call(module, function, args), do: apply(module, function, args)

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp bounded_reconcile_interval(value) when is_integer(value) do
    value
    |> max(@minimum_reconcile_interval_ms)
    |> min(@maximum_reconcile_interval_ms)
  end

  defp bounded_reconcile_interval(_value), do: @reconcile_interval_ms

  defp bounded_reconcile_batch_size(value) when is_integer(value) do
    value
    |> max(1)
    |> min(@maximum_reconcile_batch_size)
  end

  defp bounded_reconcile_batch_size(_value), do: @default_reconcile_batch_size
end
