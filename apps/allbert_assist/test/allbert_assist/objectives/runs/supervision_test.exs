defmodule AllbertAssist.Objectives.Runs.SupervisionTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Runs.Scheduler

  defmodule PausingAdapter do
    def operation(operation, state, opts) do
      test_pid = Keyword.fetch!(opts, :test_pid)
      send(test_pid, {:run_operation, state.objective.id, operation, self()})

      if operation == :execute do
        receive do
          :continue -> {:ok, Map.put(state, :response, %{message: "finished"})}
        end
      else
        {:ok, state}
      end
    end
  end

  defmodule SelectiveConfirmationAdapter do
    def operation(:propose, %{objective: objective} = state, _opts) do
      {:ok, Map.put(state, :step, List.last(AllbertAssist.Objectives.list_steps(objective.id)))}
    end

    def operation(:execute, %{objective: %{id: id}} = state, opts) do
      if id == Keyword.fetch!(opts, :confirmation_child_id) do
        {:blocked, {:needs_confirmation, "confirm-#{id}"}, state}
      else
        {:ok, Map.put(state, :response, %{message: "finished"})}
      end
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  test "acknowledgement is a hard start barrier and siblings progress around a parked child" do
    %{parent: parent, children: [parked, runnable], receipt: receipt} = frame_two()
    add_safe_step(parked)
    add_safe_step(runnable)

    assert {:error, :kickoff_not_acknowledged} = Scheduler.start_fanout(parent.id)
    assert {:ok, fresh} = Objectives.get_objective(runnable.id)
    assert fresh.run_attempt_count == 0

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: SelectiveConfirmationAdapter,
        confirmation_child_id: parked.id
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(runnable.id) do
        blocked.status == "blocked" and completed.status == "completed"
      end
    end)

    [parked_step] = Objectives.list_steps(parked.id)
    assert parked_step.status == "blocked"
    assert parked_step.confirmation_id == "confirm-#{parked.id}"

    assert %{terminal?: false} = Fanout.join_status(parent)
  end

  test "safe run crash restarts once and coordinator crash reconnects to the live run" do
    %{parent: parent, children: [first, second], receipt: receipt} = frame_two()
    add_safe_step(first)
    add_safe_step(second)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    assert_receive {:run_operation, child_id, :execute, first_run}, 2_000
    Process.exit(first_run, :kill)

    assert_receive {:run_operation, ^child_id, :execute, restarted_run}, 2_000
    refute restarted_run == first_run

    Process.exit(coordinator, :kill)

    eventually(fn ->
      case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent.id}) do
        [{pid, _}] -> pid != coordinator and Process.alive?(pid)
        _ -> false
      end
    end)

    send(restarted_run, :continue)

    # Release the other child whether it reached execute before or after the crash.
    other_id = if child_id == first.id, do: second.id, else: first.id
    release_child_when_paused(other_id)

    eventually(fn ->
      case Objectives.get_objective(parent.id) do
        {:ok, objective} -> objective.report_delivery_state == "pending"
        _ -> false
      end
    end)

    assert {:ok, restarted_child} = Objectives.get_objective(child_id)
    assert restarted_child.run_attempt_count == 2
    assert restarted_child.status == "completed"
  end

  test "unknown in-flight work parks as uncertain instead of auto-retrying" do
    %{parent: parent, children: [unknown, safe], receipt: receipt} = frame_two()
    unknown_id = unknown.id
    add_safe_step(safe)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    unknown_pid = await_paused_run(unknown.id)
    Process.exit(unknown_pid, :kill)

    safe_pid = await_paused_run(safe.id)
    send(safe_pid, :continue)

    eventually(fn ->
      with {:ok, parked} <- Objectives.get_objective(unknown.id),
           {:ok, completed} <- Objectives.get_objective(safe.id) do
        parked.status == "blocked" and
          parked.review_reason =~ "uncertain_effect" and
          parked.run_attempt_count == 1 and completed.status == "completed"
      end
    end)

    refute_receive {:run_operation, ^unknown_id, :execute, _pid}, 200
  end

  test "safe work gets only one restart and then fails honestly" do
    %{parent: parent, children: [crashing, sibling], receipt: receipt} = frame_two()
    crashing_id = crashing.id
    add_safe_step(crashing)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    first_pid = await_paused_run(crashing.id)
    Process.exit(first_pid, :kill)
    second_pid = await_paused_run(crashing.id)
    Process.exit(second_pid, :kill)

    sibling_pid = await_paused_run(sibling.id)
    send(sibling_pid, :continue)

    eventually(fn ->
      with {:ok, failed} <- Objectives.get_objective(crashing.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        failed.status == "failed" and failed.run_attempt_count == 2 and
          failed.review_reason =~ "retry_exhausted" and
          joined.join_outcome == "partial"
      end
    end)

    refute_receive {:run_operation, ^crashing_id, :execute, _pid}, 200
  end

  test "scheduler restart reconstructs live capacity without duplicating runs" do
    %{parent: parent, children: [first, second], receipt: receipt} = frame_two()
    add_safe_step(first)
    add_safe_step(second)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    first_pid = await_paused_run(first.id)
    second_pid = await_paused_run(second.id)
    old_scheduler = Process.whereis(Scheduler)
    Process.exit(old_scheduler, :kill)

    eventually(fn ->
      case Process.whereis(Scheduler) do
        pid when is_pid(pid) and pid != old_scheduler ->
          snapshot = Scheduler.snapshot()
          Map.keys(snapshot.active) |> MapSet.new() == MapSet.new([first.id, second.id])

        _ ->
          false
      end
    end)

    send(first_pid, :continue)
    send(second_pid, :continue)

    eventually(fn ->
      with {:ok, first} <- Objectives.get_objective(first.id),
           {:ok, second} <- Objectives.get_objective(second.id) do
        first.status == "completed" and second.status == "completed" and
          first.run_attempt_count == 1 and second.run_attempt_count == 1
      end
    end)
  end

  test "boot reconciliation resumes safe work and parks unknown in-flight work" do
    %{parent: parent, children: [safe, unknown], receipt: receipt} = frame_two()
    add_safe_step(safe)

    for child <- [safe, unknown] do
      assert {:ok, _running} =
               Objectives.update_objective(child, %{status: "running", run_attempt_count: 1})
    end

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id)

    eventually(fn ->
      with {:ok, resumed} <- Objectives.get_objective(safe.id),
           {:ok, parked} <- Objectives.get_objective(unknown.id) do
        resumed.status == "completed" and resumed.run_attempt_count == 2 and
          parked.status == "blocked" and parked.run_attempt_count == 1 and
          parked.review_reason =~ "uncertain_effect"
      end
    end)
  end

  defp frame_two do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{user_id: "alice", title: unique("parent"), objective: "Parallel"},
               [unique("first"), unique("second")]
             )

    on_exit(fn -> stop_fanout_processes(parent.id, Enum.map(children, & &1.id)) end)

    %{parent: parent, children: children, receipt: receipt}
  end

  defp stop_fanout_processes(parent_id, child_ids) do
    Enum.each([parent_id | child_ids], fn objective_id ->
      case Objectives.get_objective(objective_id) do
        {:ok, objective} when objective.status in ~w[open running blocked] ->
          Objectives.update_objective(objective, %{status: "cancelled"})

        _ ->
          :ok
      end
    end)

    if Process.whereis(AllbertAssist.Objectives.Runs.Scheduler),
      do: Scheduler.finish_fanout(parent_id)

    keys = [{:fanout, parent_id} | Enum.map(child_ids, &{:run, &1})]

    Enum.each(keys, &terminate_registered_process/1)
  end

  defp terminate_registered_process(key) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, key) do
      [{pid, _}] -> terminate_if_alive(pid)
      [] -> :ok
    end
  end

  defp terminate_if_alive(pid) do
    if Process.alive?(pid),
      do: DynamicSupervisor.terminate_child(AllbertAssist.Objectives.Runs.Supervisor, pid)
  end

  defp add_safe_step(child) do
    assert {:ok, _step} =
             Objectives.create_step(%{
               objective_id: child.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "list_objectives",
               action_params: %{user_id: child.user_id}
             })
  end

  defp release_child_when_paused(child_id) do
    receive do
      {:run_operation, ^child_id, :execute, pid} ->
        send(pid, :continue)

      {:run_operation, _other, :execute, pid} ->
        send(pid, :continue)
        release_child_when_paused(child_id)
    after
      2_000 -> flunk("child #{child_id} never reached execute")
    end
  end

  defp await_paused_run(child_id) do
    receive do
      {:run_operation, ^child_id, :execute, pid} -> pid
    after
      2_000 -> flunk("child #{child_id} never reached execute")
    end
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(fun, 0), do: assert(fun.())

  defp eventually(fun, attempts) do
    if fun.() do
      :ok
    else
      Process.sleep(20)
      eventually(fun, attempts - 1)
    end
  end

  defp unique(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
end
