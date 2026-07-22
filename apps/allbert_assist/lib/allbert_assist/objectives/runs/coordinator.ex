defmodule AllbertAssist.Objectives.Runs.Coordinator do
  @moduledoc """
  Rebuildable per-fan-out coordinator.

  This plain GenServer monitors temporary run workers and derives all queue
  and join truth from Objectives. It owns no durable goal loop; restart simply
  reconnects to Registry entries and re-enqueues durable children.
  """

  use GenServer, restart: :temporary

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Runs.{RunServer, Scheduler, Supervisor}
  alias AllbertAssist.Repo
  alias AllbertAssist.Signals

  def child_spec(opts) do
    parent_id = Keyword.fetch!(opts, :parent_id)

    %{
      id: {__MODULE__, parent_id},
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    parent_id = Keyword.fetch!(opts, :parent_id)

    case Registry.register(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent_id}, nil) do
      {:ok, _} ->
        Scheduler.track_coordinator(parent_id, self())
        Signals.emit_fanout(:fanout_started, %{parent_id: parent_id})

        {:ok,
         %{
           parent_id: parent_id,
           run_opts: Keyword.get(opts, :run_opts, []),
           monitors: %{}
         }, {:continue, :reconcile}}

      {:error, {:already_registered, pid}} ->
        {:stop, {:already_started, pid}}
    end
  end

  @impl true
  def handle_continue(:reconcile, state) do
    state =
      state.parent_id
      |> Fanout.children()
      |> Enum.reject(&(&1.status in ~w[completed cancelled failed abandoned]))
      |> Enum.reduce(state, &reconcile_child/2)

    {:noreply, maybe_join(state)}
  end

  @impl true
  def handle_info({:run_grant, child_id}, state), do: {:noreply, start_run(child_id, state)}

  def handle_info(:scheduler_reconcile, state), do: handle_continue(:reconcile, state)

  def handle_info({:run_terminal, child_id, _result}, state) do
    Scheduler.release(child_id)
    state = drop_monitor(state, child_id)
    {:noreply, maybe_join(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.monitors, fn {_child_id, monitor_ref} -> monitor_ref == ref end) do
      nil ->
        {:noreply, state}

      {child_id, _ref} ->
        state = %{state | monitors: Map.delete(state.monitors, child_id)}

        case Objectives.get_objective(child_id) do
          {:ok, %{status: status}}
          when status in ~w[completed cancelled failed abandoned blocked] ->
            Scheduler.release(child_id)
            {:noreply, maybe_join(state)}

          {:ok, child} ->
            retry_or_park(child, reason)
            Scheduler.release(child_id)
            {:noreply, maybe_join(state)}

          _ ->
            Scheduler.release(child_id)
            {:noreply, maybe_join(state)}
        end
    end
  end

  def handle_info(:stop_after_join, state), do: {:stop, :normal, state}

  defp reconcile_child(child, state) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:run, child.id}) do
      [{pid, _}] ->
        Scheduler.recover_slot(state.parent_id, child.id)
        monitor_run(child.id, pid, state)

      [] ->
        reconcile_missing_run(child, state)
    end
  end

  defp reconcile_missing_run(%{status: "open"} = child, state),
    do: request_or_start(child.id, state)

  defp reconcile_missing_run(%{status: "running"} = child, state) do
    if child.run_attempt_count <= 1 and Objectives.Lifecycle.retry_safety(child.id) == :safe do
      request_or_start(child.id, state)
    else
      retry_or_park(child, :missing_durable_observation)
      state
    end
  end

  defp reconcile_missing_run(_blocked_or_terminal, state), do: state

  defp request_or_start(child_id, state) do
    case Scheduler.request_slot(state.parent_id, child_id, self()) do
      :granted -> start_run(child_id, state)
      :queued -> state
    end
  end

  defp start_run(child_id, state) do
    opts = [child_id: child_id, parent_id: state.parent_id, coordinator: self()] ++ state.run_opts

    case DynamicSupervisor.start_child(Supervisor, {RunServer, opts}) do
      {:ok, pid} ->
        monitor_run(child_id, pid, state)

      {:error, {:already_started, pid}} ->
        monitor_run(child_id, pid, state)

      {:error, reason} ->
        retry_or_park_id(child_id, reason)
        Scheduler.release(child_id)
        state
    end
  end

  defp monitor_run(child_id, pid, state) do
    if Map.has_key?(state.monitors, child_id) do
      state
    else
      %{state | monitors: Map.put(state.monitors, child_id, Process.monitor(pid))}
    end
  end

  defp drop_monitor(state, child_id) do
    case Map.pop(state.monitors, child_id) do
      {nil, monitors} ->
        %{state | monitors: monitors}

      {ref, monitors} ->
        Process.demonitor(ref, [:flush])
        %{state | monitors: monitors}
    end
  end

  defp retry_or_park(child, reason) do
    case {Objectives.Lifecycle.retry_safety(child.id), child.run_attempt_count} do
      {:safe, attempts} when attempts <= 1 ->
        :ok

      {:safe, _attempts} ->
        fail_exhausted_retry(child, reason)

      {_not_safe, _attempts} ->
        Objectives.update_objective(child, %{
          status: "blocked",
          review_reason: "uncertain_effect: #{inspect(reason, limit: 10)}"
        })
    end
  end

  defp fail_exhausted_retry(child, reason) do
    reason_text = "retry_exhausted: #{inspect(reason, limit: 10)}"

    case Repo.transaction(fn -> persist_exhausted_retry(child, reason_text) end) do
      {:ok, failed} ->
        Signals.emit_fanout(:run_failed, %{
          child_id: failed.id,
          parent_id: failed.parent_objective_id,
          reason: reason_text
        })

      {:error, _reason} ->
        :ok
    end
  end

  defp persist_exhausted_retry(child, reason_text) do
    with {:ok, failed} <-
           Objectives.update_objective(child, %{
             status: "failed",
             review_reason: reason_text,
             completed_at: DateTime.utc_now()
           }),
         {:ok, _event} <-
           Objectives.create_event(%{
             objective_id: failed.id,
             kind: "run_failed",
             payload: %{reason: reason_text}
           }) do
      failed
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp retry_or_park_id(child_id, reason) do
    case Objectives.get_objective(child_id) do
      {:ok, child} -> retry_or_park(child, reason)
      _ -> :ok
    end
  end

  defp maybe_join(state) do
    case Fanout.join_status(state.parent_id) do
      %{terminal?: true} ->
        case Fanout.finalize_join(state.parent_id) do
          {:ok, %{parent: parent}} ->
            Signals.emit_fanout(:fanout_joined, %{
              parent_id: parent.id,
              status: parent.status,
              join_outcome: parent.join_outcome
            })

            Scheduler.finish_fanout(parent.id)

          _ ->
            :ok
        end

        Process.send_after(self(), :stop_after_join, 0)
        state

      _ ->
        # Safe crashed runs remain non-terminal and must be enqueued again.
        state.parent_id
        |> Fanout.children()
        |> Enum.filter(&(&1.status == "running" and not Map.has_key?(state.monitors, &1.id)))
        |> Enum.reduce(state, &request_or_start(&1.id, &2))
    end
  end
end
