defmodule AllbertAssist.Objectives.Runs.Scheduler do
  @moduledoc """
  Fair global capacity scheduler for durable fan-out runs.

  This is a plain GenServer because its state is a rebuildable scheduling
  projection; Jido lifecycle/routing adds no value. Durable queue positions
  and attempts remain in Objectives. Grants are round-robin across fan-outs
  and FIFO within each fan-out. No polling loop is used.
  """

  use GenServer

  require Logger

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Runs.{Coordinator, Supervisor}
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Settings

  @default_global 6
  @default_per_fanout 3
  @recovery_retry_delay_ms 50
  @max_recovery_retry_delay_ms 5_000
  @max_recovery_reason_chars 240

  defstruct max_global: @default_global,
            max_per_fanout: @default_per_fanout,
            active: %{},
            waiting: %{},
            rotation: [],
            coordinators: %{},
            monitor_refs: %{},
            orphan_run_monitor_refs: %{},
            recovery_attempts: %{},
            rehydration_retry_count: 0,
            rehydration_loader: nil,
            coordinator_starter: nil

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  def request_slot(parent_id, child_id, coordinator, server \\ __MODULE__) do
    GenServer.call(server, {:request, parent_id, child_id, coordinator})
  end

  def release(child_id, server \\ __MODULE__), do: GenServer.cast(server, {:release, child_id})

  def recover_slot(parent_id, child_id, server \\ __MODULE__) do
    GenServer.cast(server, {:recover_slot, parent_id, child_id})
  end

  def track_coordinator(parent_id, pid, server \\ __MODULE__) do
    GenServer.cast(server, {:track_coordinator, parent_id, pid})
  end

  def recovery_stable(parent_id, pid, server \\ __MODULE__) do
    GenServer.cast(server, {:recovery_stable, parent_id, pid})
  end

  def start_fanout(parent_id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:start_fanout, parent_id, opts})
  end

  @doc "Best-effort wake after a durable child-side decision. Startup reconciliation is the fallback."
  @spec wake_parent(String.t(), GenServer.server()) :: :ok
  def wake_parent(parent_id, server \\ __MODULE__) when is_binary(parent_id) do
    case GenServer.whereis(server) do
      nil ->
        :ok

      _pid ->
        try do
          GenServer.call(server, {:wake_parent, parent_id})
        catch
          :exit, _reason -> :ok
        end
    end
  end

  def snapshot(server \\ __MODULE__), do: GenServer.call(server, :snapshot)

  def finish_fanout(parent_id, server \\ __MODULE__) do
    GenServer.call(server, {:finish_fanout, parent_id})
  end

  @impl true
  def init(opts) do
    state = %__MODULE__{
      max_global:
        Keyword.get_lazy(opts, :max_concurrent_runs_global, fn ->
          setting("objectives.fanout.max_concurrent_runs_global", @default_global)
        end),
      max_per_fanout:
        Keyword.get_lazy(opts, :max_concurrent_runs_per_fanout, fn ->
          setting("objectives.fanout.max_concurrent_runs_per_fanout", @default_per_fanout)
        end),
      rehydration_loader: Keyword.get(opts, :rehydration_loader, &load_rehydration_snapshot/0),
      coordinator_starter: Keyword.get(opts, :coordinator_starter, &start_coordinator/1)
    }

    if Keyword.get(opts, :rehydrate?, true),
      do: {:ok, state, {:continue, :reconcile}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    {:noreply, reconcile_runnable_parents(state)}
  end

  @impl true
  def handle_call({:request, parent_id, child_id, coordinator}, _from, state) do
    cond do
      Map.has_key?(state.active, child_id) ->
        {:reply, :granted, state}

      waiting?(state, parent_id, child_id) ->
        {:reply, :queued, state}

      can_grant?(state, parent_id) and is_nil(next_grantable(state.rotation, state)) ->
        {:reply, :granted, put_active(state, parent_id, child_id)}

      true ->
        {:reply, :queued, enqueue(state, parent_id, child_id, coordinator)}
    end
  end

  def handle_call({:start_fanout, parent_id, opts}, _from, state) do
    result =
      case Objectives.get_objective(parent_id) do
        {:ok,
         %{
           fanout_role: "parent",
           kickoff_delivery_state: "acknowledged",
           report_delivery_state: "not_ready"
         }} ->
          state.coordinator_starter.(Keyword.merge(opts, parent_id: parent_id))

        {:ok, _objective} ->
          {:error, :kickoff_not_acknowledged}

        {:error, _reason} ->
          {:error, :fanout_not_found}
      end

    {:reply, normalize_start(result), state}
  end

  def handle_call({:wake_parent, parent_id}, _from, state) do
    case Map.get(state.coordinators, parent_id) do
      pid when is_pid(pid) -> send(pid, :scheduler_reconcile)
      nil -> send(self(), {:recover_coordinator, parent_id})
    end

    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state) do
    {:reply,
     %{
       active: state.active,
       waiting: state.waiting,
       rotation: state.rotation,
       max_global: state.max_global,
       max_per_fanout: state.max_per_fanout
     }, state}
  end

  def handle_call({:finish_fanout, parent_id}, _from, state) do
    state = untrack_coordinator(state, parent_id)
    state = clear_orphan_run_monitors(state, parent_id)

    active =
      state.active
      |> Enum.reject(fn {_child_id, active_parent_id} -> active_parent_id == parent_id end)
      |> Map.new()

    state = %{
      state
      | active: active,
        waiting: Map.delete(state.waiting, parent_id),
        rotation: Enum.reject(state.rotation, &(&1 == parent_id)),
        recovery_attempts: Map.delete(state.recovery_attempts, parent_id)
    }

    {:reply, :ok, grant_waiters(state)}
  end

  @impl true
  def handle_cast({:release, child_id}, state) do
    state = release_active_run(state, child_id)
    {:noreply, grant_waiters(state)}
  end

  def handle_cast({:recover_slot, parent_id, child_id}, state) do
    {:noreply, recover_live_run_slot(state, parent_id, child_id)}
  end

  def handle_cast({:track_coordinator, parent_id, pid}, state) do
    {:noreply, track_coordinator_state(state, parent_id, pid)}
  end

  def handle_cast({:recovery_stable, parent_id, pid}, state) do
    state =
      if Map.get(state.coordinators, parent_id) == pid,
        do: clear_recovery_attempt(state, parent_id),
        else: state

    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_rehydrate, state) do
    {:noreply, reconcile_runnable_parents(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.monitor_refs, ref) do
      {nil, _refs} ->
        handle_orphan_run_down(ref, state)

      {parent_id, refs} ->
        state = %{
          state
          | monitor_refs: refs,
            coordinators: Map.delete(state.coordinators, parent_id)
        }

        state = purge_waiting_parent(state, parent_id)
        state = monitor_orphaned_active_runs(state, parent_id)

        state = grant_waiters(state)

        case recovery_required(parent_id) do
          {:ok, true} ->
            log_recovery_failure(
              parent_id,
              {:coordinator_down, bounded_recovery_reason(:exit, reason)}
            )

            {:noreply, schedule_recovery_retry(state, parent_id)}

          {:ok, false} ->
            {:noreply, clear_recovery_attempt(state, parent_id)}

          {:error, reason} ->
            log_recovery_failure(parent_id, reason)
            {:noreply, schedule_recovery_retry(state, parent_id)}
        end
    end
  end

  def handle_info({:recover_coordinator, parent_id}, state) do
    case recovery_required(parent_id) do
      {:ok, true} ->
        case state.coordinator_starter.(parent_id: parent_id, recovery?: true) do
          {:ok, pid} ->
            {:noreply, track_coordinator_state(state, parent_id, pid)}

          {:error, {:already_started, pid}} ->
            {:noreply, track_coordinator_state(state, parent_id, pid)}

          {:error, reason} ->
            log_recovery_failure(parent_id, reason)
            {:noreply, schedule_recovery_retry(state, parent_id)}
        end

      {:ok, false} ->
        {:noreply, clear_recovery_attempt(state, parent_id)}

      {:error, reason} ->
        log_recovery_failure(parent_id, reason)
        {:noreply, schedule_recovery_retry(state, parent_id)}
    end
  end

  defp normalize_start({:ok, pid}), do: {:ok, pid}
  defp normalize_start({:error, {:already_started, pid}}), do: {:ok, pid}
  defp normalize_start(other), do: other

  defp can_grant?(state, parent_id) do
    map_size(state.active) < state.max_global and
      active_for(state, parent_id) < state.max_per_fanout
  end

  defp active_for(state, parent_id),
    do: Enum.count(state.active, fn {_child, parent} -> parent == parent_id end)

  defp put_active(state, parent_id, child_id) do
    %{state | active: Map.put(state.active, child_id, parent_id)}
  end

  defp waiting?(state, parent_id, child_id) do
    state.waiting |> Map.get(parent_id, []) |> Enum.any?(fn {id, _pid} -> id == child_id end)
  end

  defp enqueue(state, parent_id, child_id, coordinator) do
    waiting =
      Map.update(
        state.waiting,
        parent_id,
        [{child_id, coordinator}],
        &(&1 ++ [{child_id, coordinator}])
      )

    rotation =
      if parent_id in state.rotation, do: state.rotation, else: state.rotation ++ [parent_id]

    %{state | waiting: waiting, rotation: rotation}
  end

  defp grant_waiters(state) do
    case next_grantable(state.rotation, state) do
      nil ->
        state

      parent_id ->
        [{child_id, coordinator} | rest] = Map.fetch!(state.waiting, parent_id)
        send(coordinator, {:run_grant, child_id})

        waiting =
          if rest == [],
            do: Map.delete(state.waiting, parent_id),
            else: Map.put(state.waiting, parent_id, rest)

        rotation =
          Enum.reject(state.rotation, &(&1 == parent_id)) ++
            if(rest == [], do: [], else: [parent_id])

        state
        |> Map.put(:waiting, waiting)
        |> Map.put(:rotation, rotation)
        |> put_active(parent_id, child_id)
        |> grant_waiters()
    end
  end

  defp next_grantable(rotation, state) do
    Enum.find(rotation, &can_grant?(state, &1))
  end

  defp untrack_coordinator(state, parent_id) do
    case Map.get(state.coordinators, parent_id) do
      nil ->
        state

      _pid ->
        monitor_refs = demonitor_coordinator(state.monitor_refs, parent_id)

        %{
          state
          | coordinators: Map.delete(state.coordinators, parent_id),
            monitor_refs: monitor_refs
        }
    end
  end

  defp track_coordinator_state(state, parent_id, pid) do
    state = untrack_coordinator(state, parent_id)
    ref = Process.monitor(pid)

    %{
      state
      | coordinators: Map.put(state.coordinators, parent_id, pid),
        monitor_refs: Map.put(state.monitor_refs, ref, parent_id)
    }
  end

  defp schedule_recovery_retry(state, parent_id) do
    attempt = Map.get(state.recovery_attempts, parent_id, 0)

    delay =
      min(
        @recovery_retry_delay_ms * Integer.pow(2, min(attempt, 7)),
        @max_recovery_retry_delay_ms
      )

    Process.send_after(self(), {:recover_coordinator, parent_id}, delay)
    %{state | recovery_attempts: Map.put(state.recovery_attempts, parent_id, attempt + 1)}
  end

  defp clear_recovery_attempt(state, parent_id) do
    %{state | recovery_attempts: Map.delete(state.recovery_attempts, parent_id)}
  end

  defp reconcile_runnable_parents(state) do
    try do
      do_reconcile_runnable_parents(state)
    rescue
      exception in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
        reason = bounded_recovery_reason(:exception, exception)
        Logger.warning("fan-out scheduler reconciliation deferred reason=#{inspect(reason)}")
        schedule_rehydration_retry(state)

      exception in Exqlite.Error ->
        if transient_sqlite_error?(exception) do
          reason = bounded_recovery_reason(:exception, exception)
          Logger.warning("fan-out scheduler reconciliation deferred reason=#{inspect(reason)}")
          schedule_rehydration_retry(state)
        else
          reraise exception, __STACKTRACE__
        end
    end
  end

  defp do_reconcile_runnable_parents(state) do
    snapshot = state.rehydration_loader.()
    state = recover_live_run_slots(state, snapshot)

    state =
      Enum.reduce(snapshot, state, fn {parent, _children}, state ->
        case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent.id}) do
          [{pid, _}] ->
            send(pid, :scheduler_reconcile)
            track_coordinator_state(state, parent.id, pid)

          [] ->
            send(self(), {:recover_coordinator, parent.id})
            state
        end
      end)

    %{state | rehydration_retry_count: 0}
  end

  defp load_rehydration_snapshot do
    Fanout.runnable_parents()
    |> Enum.map(fn parent -> {parent, Fanout.children(parent.id)} end)
  end

  defp start_coordinator(opts) do
    DynamicSupervisor.start_child(Supervisor, {Coordinator, opts})
  end

  defp schedule_rehydration_retry(%{rehydration_retry_count: retries} = state) do
    delay =
      min(
        @recovery_retry_delay_ms * Integer.pow(2, min(retries, 7)),
        @max_recovery_retry_delay_ms
      )

    Process.send_after(self(), :retry_rehydrate, delay)
    %{state | rehydration_retry_count: retries + 1}
  end

  defp recovery_required(parent_id) do
    {:ok, Fanout.recovery_required?(parent_id)}
  rescue
    exception in [DBConnection.OwnershipError, DBConnection.ConnectionError] ->
      {:error, bounded_recovery_reason(:exception, exception)}

    exception in Exqlite.Error ->
      if transient_sqlite_error?(exception),
        do: {:error, bounded_recovery_reason(:exception, exception)},
        else: reraise(exception, __STACKTRACE__)
  end

  defp transient_sqlite_error?(%Exqlite.Error{message: message}) do
    message = String.downcase(message || "")

    Enum.any?(
      ["database is busy", "database is locked", "database table is locked"],
      &String.contains?(message, &1)
    )
  end

  defp bounded_recovery_reason(kind, reason) do
    detail = reason |> Redactor.redact(:signals) |> inspect(limit: 10, printable_limit: 160)
    {kind, String.slice(detail, 0, @max_recovery_reason_chars)}
  end

  defp log_recovery_failure(parent_id, reason) do
    Logger.warning(
      "fan-out coordinator recovery deferred parent=#{parent_id} reason=#{inspect(reason)}"
    )
  end

  defp recover_live_run_slots(state, snapshot) do
    Enum.reduce(snapshot, state, fn {parent, children}, state ->
      Enum.reduce(children, state, fn child, state ->
        recover_live_run_slot(state, parent.id, child.id)
      end)
    end)
  end

  # A reconstructed slot must be monitored before coordinator recovery begins.
  # Otherwise a worker that exits between Registry discovery and coordinator
  # attachment can leave a permanently occupied global-capacity slot.
  defp recover_live_run_slot(state, parent_id, child_id) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:run, child_id}) do
      [{pid, _value}] ->
        state
        |> put_active(parent_id, child_id)
        |> monitor_recovered_run(parent_id, child_id, pid)

      [] ->
        release_active_run(state, child_id)
    end
  end

  defp monitor_recovered_run(state, parent_id, child_id, pid) do
    if orphan_run_monitored?(state, child_id) do
      state
    else
      ref = Process.monitor(pid)

      %{
        state
        | orphan_run_monitor_refs:
            Map.put(state.orphan_run_monitor_refs, ref, {parent_id, child_id})
      }
    end
  end

  defp release_active_run(state, child_id) do
    {matching, remaining} =
      Enum.split_with(state.orphan_run_monitor_refs, fn {_ref, {_parent_id, id}} ->
        id == child_id
      end)

    Enum.each(matching, fn {ref, _value} -> Process.demonitor(ref, [:flush]) end)

    %{
      state
      | active: Map.delete(state.active, child_id),
        orphan_run_monitor_refs: Map.new(remaining)
    }
  end

  defp purge_waiting_parent(state, parent_id) do
    %{
      state
      | waiting: Map.delete(state.waiting, parent_id),
        rotation: Enum.reject(state.rotation, &(&1 == parent_id))
    }
  end

  defp monitor_orphaned_active_runs(state, parent_id) do
    state.active
    |> Enum.filter(fn {_child_id, active_parent_id} -> active_parent_id == parent_id end)
    |> Enum.reduce(state, fn {child_id, _parent_id}, state ->
      monitor_or_release_orphan_run(state, parent_id, child_id)
    end)
  end

  defp monitor_or_release_orphan_run(state, parent_id, child_id) do
    if orphan_run_monitored?(state, child_id),
      do: state,
      else: monitor_or_release_untracked_run(state, parent_id, child_id)
  end

  defp monitor_or_release_untracked_run(state, parent_id, child_id) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:run, child_id}) do
      [{pid, _value}] ->
        ref = Process.monitor(pid)

        %{
          state
          | orphan_run_monitor_refs:
              Map.put(state.orphan_run_monitor_refs, ref, {parent_id, child_id})
        }

      [] ->
        %{state | active: Map.delete(state.active, child_id)}
    end
  end

  defp orphan_run_monitored?(state, child_id) do
    Enum.any?(state.orphan_run_monitor_refs, fn {_ref, {_parent_id, id}} -> id == child_id end)
  end

  defp handle_orphan_run_down(ref, state) do
    case Map.pop(state.orphan_run_monitor_refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {{_parent_id, child_id}, refs} ->
        state = %{
          state
          | orphan_run_monitor_refs: refs,
            active: Map.delete(state.active, child_id)
        }

        {:noreply, grant_waiters(state)}
    end
  end

  defp clear_orphan_run_monitors(state, parent_id) do
    {matching, remaining} =
      Enum.split_with(state.orphan_run_monitor_refs, fn {_ref, {id, _child_id}} ->
        id == parent_id
      end)

    Enum.each(matching, fn {ref, _value} -> Process.demonitor(ref, [:flush]) end)
    %{state | orphan_run_monitor_refs: Map.new(remaining)}
  end

  defp demonitor_coordinator(monitor_refs, parent_id) do
    case Enum.find(monitor_refs, fn {_ref, id} -> id == parent_id end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitor_refs, ref)

      nil ->
        monitor_refs
    end
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_integer(value) -> value
      _ -> default
    end
  end
end
