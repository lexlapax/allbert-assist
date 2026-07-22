defmodule AllbertAssist.Objectives.Runs.Scheduler do
  @moduledoc """
  Fair global capacity scheduler for durable fan-out runs.

  This is a plain GenServer because its state is a rebuildable scheduling
  projection; Jido lifecycle/routing adds no value. Durable queue positions
  and attempts remain in Objectives. Grants are round-robin across fan-outs
  and FIFO within each fan-out. No polling loop is used.
  """

  use GenServer

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Runs.{Coordinator, Supervisor}
  alias AllbertAssist.Settings

  @default_global 6
  @default_per_fanout 3

  defstruct max_global: @default_global,
            max_per_fanout: @default_per_fanout,
            active: %{},
            waiting: %{},
            rotation: [],
            coordinators: %{},
            monitor_refs: %{}

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

  def start_fanout(parent_id, opts \\ [], server \\ __MODULE__) do
    GenServer.call(server, {:start_fanout, parent_id, opts})
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
        end)
    }

    if Keyword.get(opts, :rehydrate?, true),
      do: {:ok, state, {:continue, :reconcile}},
      else: {:ok, state}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    Enum.each(Fanout.runnable_parents(), fn parent ->
      case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent.id}) do
        [{pid, _}] -> send(pid, :scheduler_reconcile)
        [] -> send(self(), {:recover_coordinator, parent.id})
      end
    end)

    {:noreply, state}
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
        {:ok, %{fanout_role: "parent", kickoff_delivery_state: "acknowledged"}} ->
          DynamicSupervisor.start_child(
            Supervisor,
            {Coordinator, Keyword.merge(opts, parent_id: parent_id)}
          )

        {:ok, _objective} ->
          {:error, :kickoff_not_acknowledged}

        {:error, _reason} ->
          {:error, :fanout_not_found}
      end

    {:reply, normalize_start(result), state}
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

    active =
      state.active
      |> Enum.reject(fn {_child_id, active_parent_id} -> active_parent_id == parent_id end)
      |> Map.new()

    state = %{
      state
      | active: active,
        waiting: Map.delete(state.waiting, parent_id),
        rotation: Enum.reject(state.rotation, &(&1 == parent_id))
    }

    {:reply, :ok, grant_waiters(state)}
  end

  @impl true
  def handle_cast({:release, child_id}, state) do
    state = %{state | active: Map.delete(state.active, child_id)}
    {:noreply, grant_waiters(state)}
  end

  def handle_cast({:recover_slot, parent_id, child_id}, state) do
    {:noreply, put_active(state, parent_id, child_id)}
  end

  def handle_cast({:track_coordinator, parent_id, pid}, state) do
    state = untrack_coordinator(state, parent_id)
    ref = Process.monitor(pid)

    {:noreply,
     %{
       state
       | coordinators: Map.put(state.coordinators, parent_id, pid),
         monitor_refs: Map.put(state.monitor_refs, ref, parent_id)
     }}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    case Map.pop(state.monitor_refs, ref) do
      {nil, _refs} ->
        {:noreply, state}

      {parent_id, refs} ->
        state = %{
          state
          | monitor_refs: refs,
            coordinators: Map.delete(state.coordinators, parent_id)
        }

        if recoverable_parent?(parent_id), do: send(self(), {:recover_coordinator, parent_id})
        {:noreply, state}
    end
  end

  def handle_info({:recover_coordinator, parent_id}, state) do
    case DynamicSupervisor.start_child(Supervisor, {Coordinator, parent_id: parent_id}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      {:error, _reason} -> :ok
    end

    {:noreply, state}
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

  defp demonitor_coordinator(monitor_refs, parent_id) do
    case Enum.find(monitor_refs, fn {_ref, id} -> id == parent_id end) do
      {ref, _} ->
        Process.demonitor(ref, [:flush])
        Map.delete(monitor_refs, ref)

      nil ->
        monitor_refs
    end
  end

  defp recoverable_parent?(parent_id) do
    case Objectives.get_objective(parent_id) do
      {:ok, %{status: status}} when status in ~w[open running blocked] ->
        Enum.any?(
          Fanout.children(parent_id),
          &(&1.status not in ~w[completed cancelled failed abandoned])
        )

      _ ->
        false
    end
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} when is_integer(value) -> value
      _ -> default
    end
  end
end
