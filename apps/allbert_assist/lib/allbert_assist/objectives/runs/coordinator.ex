defmodule AllbertAssist.Objectives.Runs.Coordinator do
  @moduledoc """
  Rebuildable per-fan-out coordinator.

  This plain GenServer monitors temporary run workers and derives all queue
  and join truth from Objectives. It owns no durable goal loop; restart simply
  reconnects to Registry entries and re-enqueues durable children.
  """

  use GenServer, restart: :temporary

  require Logger

  alias AllbertAssist.Database.TransientError
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Runs.{RunServer, Scheduler, Supervisor}
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Signals

  @max_review_reason_chars 240
  @join_retry_delay_ms 50
  @max_join_retry_delay_ms 5_000
  @run_start_retry_delay_ms 50
  @max_run_start_retry_delay_ms 5_000

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

        recovery? = Keyword.get(opts, :recovery?, false)
        unless recovery?, do: Signals.emit_fanout(:fanout_started, %{parent_id: parent_id})

        {:ok,
         %{
           parent_id: parent_id,
           run_opts: Keyword.get(opts, :run_opts, []),
           monitors: %{},
           recovery?: recovery?,
           join_reconciler: Keyword.get(opts, :join_reconciler, &Fanout.reconcile_parent/2),
           join_retry_count: 0,
           run_starter:
             Keyword.get(opts, :run_starter, fn child_spec ->
               DynamicSupervisor.start_child(Supervisor, child_spec)
             end),
           run_start_retries: %{},
           pre_effect_retries: %{}
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
  def handle_info(:retry_join, state), do: {:noreply, maybe_join(state)}

  def handle_info({:run_terminal, child_id, result}, state) do
    Scheduler.release(child_id)
    state = drop_monitor(state, child_id)
    state = reconcile_terminal_state(child_id, result, state)
    maybe_schedule_blocked_reconcile(child_id)
    {:noreply, maybe_join(state)}
  end

  def handle_info({:durable_terminal, child_id}, state) do
    Scheduler.release(child_id)
    state = drop_monitor(state, child_id)
    {:noreply, maybe_join(state)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Enum.find(state.monitors, fn {_child_id, monitor_ref} -> monitor_ref == ref end) do
      nil ->
        {:noreply, state}

      {child_id, _ref} ->
        handle_run_down(child_id, reason, state)
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

  defp reconcile_missing_run(%{status: "blocked"} = child, state) do
    case Objectives.Lifecycle.reconcile_blocked(child.id) do
      {:ok, :runnable} ->
        request_or_start(child.id, state)

      {:ok, :parked} ->
        state

      {:ok, {:terminalized, _child}} ->
        state

      {:error, reason} ->
        Logger.warning(
          "fan-out blocked-child reconciliation failed child=#{child.id} reason=#{inspect(reason)}"
        )

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

    case state.run_starter.({RunServer, opts}) do
      {:ok, pid} ->
        monitor_run(child_id, pid, state)

      {:error, {:already_started, pid}} ->
        monitor_run(child_id, pid, state)

      {:error, reason} ->
        Logger.warning(
          "fan-out worker start failed before execution child=#{child_id} reason=#{inspect(reason)}"
        )

        Scheduler.release(child_id)
        schedule_run_start_retry(state, child_id)
    end
  end

  defp handle_run_down(child_id, reason, state) do
    state = %{state | monitors: Map.delete(state.monitors, child_id)}
    result = Objectives.get_objective(child_id)
    reconcile_run_down(result, child_id, reason, state)
  end

  defp reconcile_run_down({:ok, %{status: status}}, child_id, _reason, state)
       when status in ~w[completed cancelled failed abandoned blocked] do
    Scheduler.release(child_id)
    maybe_reconcile_blocked(status)
    {:noreply, maybe_join(state)}
  end

  defp reconcile_run_down({:ok, child}, child_id, reason, state) do
    state = recover_run_failure(child, reason, state)
    Scheduler.release(child_id)
    {:noreply, maybe_join(state)}
  end

  defp reconcile_run_down(_missing, child_id, _reason, state) do
    Scheduler.release(child_id)
    {:noreply, maybe_join(state)}
  end

  defp maybe_reconcile_blocked("blocked"), do: send(self(), :scheduler_reconcile)
  defp maybe_reconcile_blocked(_status), do: :ok

  defp monitor_run(child_id, pid, state) do
    if Map.has_key?(state.monitors, child_id) do
      state
    else
      %{
        state
        | monitors: Map.put(state.monitors, child_id, Process.monitor(pid)),
          run_start_retries: Map.delete(state.run_start_retries, child_id)
      }
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

  # The worker result is advisory; the durable objective is authoritative. A
  # worker that exits normally while its objective is still running failed to
  # persist a terminal observation and must enter the same bounded recovery
  # path as a crashed worker. Without this reconciliation, maybe_join/1 sees an
  # unmonitored running child and can start it repeatedly.
  defp reconcile_terminal_state(child_id, result, state) do
    case Objectives.get_objective(child_id) do
      {:ok, %{status: status}} when status in ~w[completed cancelled failed abandoned blocked] ->
        state

      {:ok, child} ->
        recover_run_failure(child, terminal_failure_reason(result), state)

      _other ->
        state
    end
  end

  defp terminal_failure_reason({:error, reason}), do: {:lifecycle_error, reason}
  defp terminal_failure_reason(_result), do: :terminal_without_durable_observation

  defp recover_run_failure(child, reason, state) do
    if pre_effect_database_failure?(child, reason) do
      Logger.warning(
        "fan-out child start deferred before durable attempt child=#{child.id} " <>
          "reason=#{bounded_review_reason("transient_database", reason)}"
      )

      schedule_pre_effect_retry(state, child.id)
    else
      retry_or_park(child, reason)
      state
    end
  end

  defp pre_effect_database_failure?(child, reason) do
    child.status == "open" and (child.run_attempt_count || 0) == 0 and
      TransientError.transient?(reason)
  end

  defp maybe_schedule_blocked_reconcile(child_id) do
    case Objectives.get_objective(child_id) do
      {:ok, %{status: "blocked"}} -> send(self(), :scheduler_reconcile)
      _other -> :ok
    end
  end

  defp retry_or_park(child, reason) do
    case {Objectives.Lifecycle.retry_safety(child.id), child.run_attempt_count} do
      {:safe, attempts} when attempts <= 1 ->
        :ok

      {:safe, _attempts} ->
        fail_exhausted_retry(child, reason)

      {_not_safe, _attempts} ->
        reason_text = bounded_review_reason("uncertain_effect", reason)

        TerminalTransitions.transition_active_child(
          child,
          %{status: "blocked", review_reason: reason_text},
          "run_blocked",
          %{reason: reason_text},
          signal: {:run_blocked, %{reason: reason_text}}
        )
    end
  end

  defp fail_exhausted_retry(child, reason) do
    reason_text = bounded_review_reason("retry_exhausted", reason)

    case TerminalTransitions.terminalize_child(
           child,
           %{
             status: "failed",
             review_reason: reason_text,
             completed_at: DateTime.utc_now()
           },
           "run_failed",
           %{reason: reason_text},
           signal: {:run_failed, %{reason: reason_text}}
         ) do
      {:ok, _transition} ->
        :ok

      {:error, _reason} ->
        :ok
    end
  end

  defp bounded_review_reason(prefix, reason) do
    detail = reason |> Redactor.redact(:signals) |> inspect(limit: 10, printable_limit: 160)
    String.slice("#{prefix}: #{detail}", 0, @max_review_reason_chars)
  end

  defp maybe_join(state) do
    case reconcile_join(state) do
      {:ok, {joined, parent}} when joined in [:joined_now, :already_joined] ->
        case Objectives.Lifecycle.reconcile_confirmation_outcomes(parent.id) do
          :ok ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "fan-out confirmation outcome reconciliation failed parent=#{parent.id} reason=#{inspect(reason)}"
            )
        end

        Scheduler.finish_fanout(parent.id)
        Process.send_after(self(), :stop_after_join, 0)
        %{state | join_retry_count: 0}

      {:ok, :not_terminal} ->
        Scheduler.recovery_stable(state.parent_id, self())

        # Safe crashed runs remain non-terminal and must be enqueued again.
        state.parent_id
        |> Fanout.children()
        |> Enum.filter(&(&1.status == "running" and not Map.has_key?(state.monitors, &1.id)))
        |> Enum.reduce(%{state | join_retry_count: 0}, &request_or_start(&1.id, &2))

      {:error, :fanout_parent_not_found} ->
        Logger.warning(
          "fan-out coordinator retired because durable parent is absent parent=#{state.parent_id}"
        )

        Scheduler.finish_fanout(state.parent_id)
        Process.send_after(self(), :stop_after_join, 0)
        %{state | join_retry_count: 0}

      {:error, reason} ->
        Logger.warning(
          "fan-out parent reconciliation failed parent=#{state.parent_id} reason=#{inspect(reason)}"
        )

        retry_join(state)
    end
  end

  defp reconcile_join(state) do
    state.join_reconciler.(state.parent_id, recovered?: state.recovery?)
  rescue
    exception ->
      if TransientError.transient?(exception) do
        {:error,
         {:join_reconcile_exception, bounded_review_reason("join_reconcile_exception", exception)}}
      else
        reraise exception, __STACKTRACE__
      end
  catch
    :exit, reason ->
      if TransientError.transient?(reason) do
        {:error,
         {:join_reconcile_exception, bounded_review_reason("join_reconcile_exit", reason)}}
      else
        exit(reason)
      end
  end

  defp retry_join(%{join_retry_count: retries} = state) do
    delay =
      min(
        @join_retry_delay_ms * Integer.pow(2, min(retries, 7)),
        @max_join_retry_delay_ms
      )

    Process.send_after(self(), :retry_join, delay)
    %{state | join_retry_count: retries + 1}
  end

  defp schedule_run_start_retry(state, child_id) do
    attempt = Map.get(state.run_start_retries, child_id, 0)

    delay =
      min(
        @run_start_retry_delay_ms * Integer.pow(2, min(attempt, 7)),
        @max_run_start_retry_delay_ms
      )

    Process.send_after(self(), :scheduler_reconcile, delay)
    %{state | run_start_retries: Map.put(state.run_start_retries, child_id, attempt + 1)}
  end

  defp schedule_pre_effect_retry(state, child_id) do
    attempt = Map.get(state.pre_effect_retries, child_id, 0)

    delay =
      min(
        @run_start_retry_delay_ms * Integer.pow(2, min(attempt, 7)),
        @max_run_start_retry_delay_ms
      )

    Process.send_after(self(), :scheduler_reconcile, delay)
    %{state | pre_effect_retries: Map.put(state.pre_effect_retries, child_id, attempt + 1)}
  end
end
