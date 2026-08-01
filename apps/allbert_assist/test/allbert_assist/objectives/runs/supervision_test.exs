defmodule AllbertAssist.Objectives.Runs.SupervisionTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  import Ecto.Query

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Store.Persistence, as: ConfirmationPersistence
  alias AllbertAssist.Execution.Audit
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Runs.Scheduler
  alias AllbertAssist.Objectives.Runs.Worker.Grounding
  alias AllbertAssist.Objectives.Steering
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.YamlCodec

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

  defmodule DurableConfirmationAdapter do
    def operation(:propose, %{objective: objective} = state, _opts) do
      {:ok, Map.put(state, :step, List.last(AllbertAssist.Objectives.list_steps(objective.id)))}
    end

    def operation(:execute, %{objective: %{id: id}} = state, opts) do
      if id == Keyword.fetch!(opts, :confirmation_child_id) do
        confirmation_id = Keyword.fetch!(opts, :confirmation_id)

        case AllbertAssist.Confirmations.read(confirmation_id) do
          {:ok, %{"status" => "approved"}} ->
            send(Keyword.fetch!(opts, :test_pid), {:approved_target_executed, id})
            {:ok, Map.put(state, :response, %{message: "approved target finished"})}

          {:ok, %{"status" => "pending"}} ->
            {:blocked, {:needs_confirmation, confirmation_id}, state}

          {:ok, %{"status" => status}} ->
            {:error, {:confirmation_not_approved, status}, state}
        end
      else
        {:ok, Map.put(state, :response, %{message: "sibling finished"})}
      end
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule TerminalPersistenceFailureAdapter do
    def operation(:execute, %{objective: %{id: id}} = state, opts) do
      message =
        if id == Keyword.fetch!(opts, :failing_child_id) do
          # 600 control characters fit the objective field but exceed the
          # event payload after JSON escaping, forcing terminal persistence to fail.
          String.duplicate(<<1>>, 600)
        else
          "finished"
        end

      {:ok, Map.put(state, :response, %{message: message})}
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule FreshChildAdapter do
    def operation(:execute, state, _opts),
      do: {:ok, Map.put(state, :response, %{message: "fresh child finished"})}

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

  test "approval queues a parked child through supervision and joins exactly once" do
    %{parent: parent, children: [parked, sibling], receipt: receipt} = frame_two()
    step = add_safe_step(parked)
    add_safe_step(sibling)

    assert {:ok, confirmation} = create_child_confirmation(parked, step)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: DurableConfirmationAdapter,
        confirmation_child_id: parked.id,
        confirmation_id: confirmation["id"],
        test_pid: self()
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id) do
        blocked.status == "blocked" and completed.status == "completed"
      end
    end)

    for tampered <- [
          put_in(confirmation, ["target_action", "name"], "run_shell_command"),
          put_in(confirmation, ["origin", "user_id"], "mallory")
        ] do
      write_confirmation!(tampered)

      assert {:ok, denied} =
               Runner.run("approve_confirmation", %{id: confirmation["id"]}, %{
                 user_id: "alice",
                 actor: "alice",
                 channel: "test"
               })

      assert denied.status == :denied
      assert denied.error == :stale_fanout_confirmation
      assert {:ok, %{"status" => "pending"}} = Confirmations.read(confirmation["id"])
    end

    write_confirmation!(confirmation)

    assert {:ok, approval} =
             Runner.run("approve_confirmation", %{id: confirmation["id"]}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert approval.status == :completed
    assert approval.confirmation["status"] == "approved"

    eventually(fn ->
      with {:ok, completed} <- Objectives.get_objective(parked.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        completed.status == "completed" and completed.run_attempt_count == 1 and
          joined.report_composition_state == "queued" and
          joined.report_delivery_state == "not_ready"
      end
    end)

    assert_receive {:approved_target_executed, parked_id}, 2_000
    assert parked_id == parked.id
    assert [%{status: "completed"}] = Objectives.list_steps(parked.id)
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1

    assert {:ok, duplicate} =
             Runner.run("approve_confirmation", %{id: confirmation["id"]}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert duplicate.status == :completed
    refute_receive {:approved_target_executed, _id}, 200
  end

  test "unversioned approval recovers a uniquely linked parked child through supervision" do
    %{parent: parent, children: [parked, sibling], receipt: receipt} = frame_two()
    step = add_safe_step(parked)
    add_safe_step(sibling)

    assert {:ok, confirmation} = create_child_confirmation(parked, step)
    legacy_confirmation = rewrite_as_candidate_unversioned!(confirmation)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: DurableConfirmationAdapter,
        confirmation_child_id: parked.id,
        confirmation_id: legacy_confirmation["id"],
        test_pid: self()
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id) do
        blocked.status == "blocked" and completed.status == "completed"
      end
    end)

    assert {:ok, approval} =
             Runner.run("approve_confirmation", %{id: legacy_confirmation["id"]}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert approval.status == :completed
    assert approval.confirmation["status"] == "approved"

    eventually(fn ->
      with {:ok, completed} <- Objectives.get_objective(parked.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        completed.status == "completed" and joined.report_composition_state == "queued" and
          joined.report_delivery_state == "not_ready"
      end
    end)

    assert_receive {:approved_target_executed, parked_id}, 2_000
    assert parked_id == parked.id
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "ambiguous unversioned approval is denied and remains pending" do
    %{children: [first, second]} = frame_two()
    first_step = add_safe_step(first)
    second_step = add_safe_step(second)

    assert {:ok, confirmation} = create_child_confirmation(first, first_step)
    legacy_confirmation = rewrite_as_provenance_free_unversioned!(confirmation)

    assert {:ok, _first_step} =
             Objectives.transition_step(first_step, "blocked", %{
               confirmation_id: legacy_confirmation["id"]
             })

    assert {:ok, _second_step} =
             Objectives.transition_step(second_step, "blocked", %{
               confirmation_id: legacy_confirmation["id"]
             })

    assert {:ok, response} =
             Runner.run("approve_confirmation", %{id: legacy_confirmation["id"]}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert response.status == :denied
    assert response.error == :ambiguous_confirmation_target

    assert {:ok, %{"status" => "pending"}} =
             Confirmations.read(legacy_confirmation["id"])
  end

  test "policy-denied approval wakes the exact child and joins the parent as partial" do
    assert {:ok, original_policy} = Settings.get("permissions.external_network")

    on_exit(fn ->
      Settings.put("permissions.external_network", original_policy, %{audit?: false})
    end)

    assert {:ok, _setting} =
             Settings.put("permissions.external_network", "needs_confirmation", %{audit?: false})

    %{parent: parent, children: [parked, sibling], receipt: receipt} = frame_two()
    step = add_action_step(parked, "external_network_request")
    add_safe_step(sibling)

    assert {:ok, confirmation} =
             create_child_confirmation(parked, step,
               permission: :external_network,
               execution_mode: :req_http,
               decision: :needs_confirmation
             )

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: DurableConfirmationAdapter,
        confirmation_child_id: parked.id,
        confirmation_id: confirmation["id"],
        test_pid: self()
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id) do
        blocked.status == "blocked" and completed.status == "completed"
      end
    end)

    assert {:ok, _setting} =
             Settings.put("permissions.external_network", "denied", %{audit?: false})

    assert {:ok, response} =
             Runner.run("approve_confirmation", %{id: confirmation["id"]}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert response.status == :completed
    assert response.confirmation["status"] == "denied"
    assert response.actions |> hd() |> get_in([:confirmation_metadata, :blocked_by_policy?])
    refute response.actions |> hd() |> get_in([:confirmation_metadata, :target_resumed?])

    eventually(fn ->
      with {:ok, cancelled} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        cancelled.status == "cancelled" and completed.status == "completed" and
          joined.status == "completed" and joined.join_outcome == "partial" and
          joined.report_composition_state == "queued" and
          joined.report_delivery_state == "not_ready"
      end
    end)

    assert [%{status: "cancelled"}] = Objectives.list_steps(parked.id)
    refute_receive {:approved_target_executed, _id}, 200
  end

  test "policy-denied approval leaves a tampered fan-out confirmation pending" do
    assert {:ok, original_policy} = Settings.get("permissions.external_network")

    on_exit(fn ->
      Settings.put("permissions.external_network", original_policy, %{audit?: false})
    end)

    assert {:ok, _setting} =
             Settings.put("permissions.external_network", "needs_confirmation", %{audit?: false})

    %{parent: parent, children: [parked, sibling], receipt: receipt} = frame_two()
    step = add_action_step(parked, "external_network_request")
    add_safe_step(sibling)

    assert {:ok, confirmation} =
             create_child_confirmation(parked, step,
               permission: :external_network,
               execution_mode: :req_http,
               decision: :needs_confirmation
             )

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: DurableConfirmationAdapter,
        confirmation_child_id: parked.id,
        confirmation_id: confirmation["id"],
        test_pid: self()
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id) do
        blocked.status == "blocked" and completed.status == "completed"
      end
    end)

    tampered = put_in(confirmation, ["target_action", "name"], "run_shell_command")
    write_confirmation!(tampered)

    assert {:ok, _setting} =
             Settings.put("permissions.external_network", "denied", %{audit?: false})

    assert {:ok, response} =
             Runner.run("approve_confirmation", %{id: confirmation["id"]}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert response.status == :denied
    assert response.error == :stale_fanout_confirmation
    assert {:ok, %{"status" => "pending"}} = Confirmations.read(confirmation["id"])
    assert {:ok, %{status: "blocked"}} = Objectives.get_objective(parked.id)

    assert {:ok, %{status: "open", report_delivery_state: "not_ready"}} =
             Objectives.get_objective(parent.id)

    refute_receive {:approved_target_executed, _id}, 200
  end

  test "denial cancels only the parked child and lets the parent report partial" do
    %{parent: parent, children: [parked, sibling], receipt: receipt} = frame_two()
    step = add_safe_step(parked)
    add_safe_step(sibling)

    assert {:ok, confirmation} = create_child_confirmation(parked, step)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: DurableConfirmationAdapter,
        confirmation_child_id: parked.id,
        confirmation_id: confirmation["id"],
        test_pid: self()
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      match?({:ok, %{status: "blocked"}}, Objectives.get_objective(parked.id))
    end)

    assert {:ok, denial} =
             Runner.run(
               "deny_confirmation",
               %{id: confirmation["id"], reason: "operator declined"},
               %{user_id: "alice", actor: "alice", channel: "test"}
             )

    assert denial.status == :completed

    eventually(fn ->
      with {:ok, cancelled} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        cancelled.status == "cancelled" and completed.status == "completed" and
          joined.status == "completed" and joined.join_outcome == "partial"
      end
    end)

    assert [%{status: "cancelled"}] = Objectives.list_steps(parked.id)
    refute_receive {:approved_target_executed, _id}, 200
  end

  test "denial reconciles a grounded child after its bound resume packet is tampered" do
    %{parent: parent, children: [parked, sibling], receipt: receipt} = frame_two_with_budget()
    step = add_safe_step(parked)
    add_safe_step(sibling)

    assert %{source: :conversation_manager} = Grounding.resolve(parked)
    assert {:ok, confirmation} = create_child_confirmation(parked, step)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: DurableConfirmationAdapter,
        confirmation_child_id: parked.id,
        confirmation_id: confirmation["id"],
        test_pid: self()
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(parked.id),
           [blocked_step] <- Objectives.list_steps(parked.id) do
        blocked.status == "blocked" and blocked_step.status == "blocked" and
          is_binary(blocked_step.confirmation_resume_params_sha256) and
          byte_size(blocked_step.confirmation_resume_params_sha256) == 64
      else
        _other -> false
      end
    end)

    assert {:ok, pending} = Confirmations.read(confirmation["id"])
    tampered = Map.put(pending, "resume_params_ref", %{"limit" => 5})
    write_confirmation!(tampered)

    assert {:error, :confirmation_resume_params_mismatch} =
             Objectives.fanout_confirmation_target(tampered)

    assert {:ok, denial} =
             Runner.run(
               "deny_confirmation",
               %{id: confirmation["id"], reason: "operator declined tampered request"},
               %{user_id: "alice", actor: "alice", channel: "test"}
             )

    assert denial.status == :completed
    assert denial.confirmation["status"] == "denied"

    eventually(fn ->
      with {:ok, cancelled} <- Objectives.get_objective(parked.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        cancelled.status == "cancelled" and completed.status == "completed" and
          joined.status == "completed" and joined.join_outcome == "partial"
      end
    end)

    assert [%{status: "cancelled"}] = Objectives.list_steps(parked.id)
    refute_receive {:approved_target_executed, _id}, 200
  end

  test "a real confirmed action resumes once through DefaultAdapter and atomic fan-in" do
    workspace =
      Path.join(
        System.tmp_dir!(),
        "allbert-fanout-confirmed-shell-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(workspace)
    on_exit(fn -> File.rm_rf!(workspace) end)

    assert {:ok, _setting} =
             Settings.put("permissions.command_execute", "allowed", %{audit?: false})

    assert {:ok, _setting} = Settings.put("execution.local.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("execution.local.allowed_roots", [workspace], %{audit?: false})

    %{parent: parent, children: [confirmed, sibling], receipt: receipt} = frame_two()

    assert {:ok, shell_step} =
             Objectives.create_step(%{
               objective_id: confirmed.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "run_shell_command",
               action_params: %{executable: "pwd", args: [], cwd: workspace}
             })

    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id)

    eventually(fn ->
      match?({:ok, %{status: "blocked"}}, Objectives.get_objective(confirmed.id))
    end)

    [%{confirmation_id: confirmation_id, status: "blocked"}] =
      Objectives.list_steps(confirmed.id)

    assert is_binary(confirmation_id)
    assert {:ok, pending} = Confirmations.read(confirmation_id)
    assert pending["objective_id"] == confirmed.id
    assert pending["step_id"] == shell_step.id
    assert get_in(pending, ["target_action", "name"]) == "run_shell_command"

    before_successes = command_success_count(workspace)

    assert {:ok, approval} =
             Runner.run(
               "approve_confirmation",
               %{id: confirmation_id, reason: "run the harmless fixture"},
               %{user_id: "alice", actor: "alice", channel: "test"}
             )

    assert approval.status == :completed
    assert approval.confirmation["status"] == "approved"
    assert approval.message =~ "queued to resume under fan-out supervision"

    eventually(fn ->
      with {:ok, child} <- Objectives.get_objective(confirmed.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        child.status == "completed" and child.run_attempt_count == 1 and
          joined.status == "completed" and joined.join_outcome == "success"
      end
    end)

    assert [%{status: "completed"}] = Objectives.list_steps(confirmed.id)
    assert command_success_count(workspace) == before_successes + 1
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1

    eventually(fn ->
      with {:ok, resolved} <- Confirmations.read(confirmation_id) do
        get_in(resolved, ["operator_resolution", "target_status"]) == "completed" and
          get_in(resolved, ["operator_resolution", "target_resumed?"]) == true
      end
    end)

    assert {:ok, duplicate} =
             Runner.run("approve_confirmation", %{id: confirmation_id}, %{
               user_id: "alice",
               actor: "alice",
               channel: "test"
             })

    assert duplicate.status == :completed
    Process.sleep(100)
    assert command_success_count(workspace) == before_successes + 1
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
        {:ok, objective} ->
          objective.report_composition_state == "queued" and
            objective.report_delivery_state == "not_ready"

        _ ->
          false
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
    crash_reason = {:fixture_crash, String.duplicate("x", 500)}
    Process.exit(first_pid, crash_reason)
    second_pid = await_paused_run(crashing.id)
    Process.exit(second_pid, crash_reason)

    sibling_pid = await_paused_run(sibling.id)
    send(sibling_pid, :continue)

    eventually(fn ->
      with {:ok, failed} <- Objectives.get_objective(crashing.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        failed.status == "failed" and failed.run_attempt_count == 2 and
          failed.review_reason =~ "retry_exhausted" and
          String.length(failed.review_reason) <= 240 and
          joined.join_outcome == "partial"
      end
    end)

    refute_receive {:run_operation, ^crashing_id, :execute, _pid}, 200
  end

  test "safe recovery consumes the compiled plan's frozen worker-attempt limit" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.max_worker_attempts_per_child", 3, %{
               audit?: false
             })

    %{parent: parent, children: [restarting, sibling], receipt: receipt} =
      frame_two_with_budget()

    add_safe_step(restarting)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    first_pid = await_paused_run(restarting.id)
    Process.exit(first_pid, :kill)
    second_pid = await_paused_run(restarting.id)
    Process.exit(second_pid, :kill)
    third_pid = await_paused_run(restarting.id)
    send(third_pid, :continue)
    release_child_when_paused(sibling.id)

    eventually(fn ->
      with {:ok, completed} <- Objectives.get_objective(restarting.id) do
        completed.status == "completed" and completed.run_attempt_count == 3
      end
    end)
  end

  test "compiled child with missing parent provenance receives no legacy crash retry" do
    %{parent: parent, children: [untrusted, sibling], receipt: receipt} =
      frame_two_with_budget()

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [proposer_hint: nil, updated_at: DateTime.utc_now()])

    add_safe_step(untrusted)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    untrusted_id = untrusted.id
    first_pid = await_paused_run(untrusted_id)
    Process.exit(first_pid, :kill)
    release_child_when_paused(sibling.id)

    eventually(fn ->
      with {:ok, failed} <- Objectives.get_objective(untrusted_id) do
        failed.status == "failed" and failed.run_attempt_count == 1 and
          failed.review_reason =~ "retry_exhausted"
      end
    end)

    refute_receive {:run_operation, ^untrusted_id, :execute, _pid}, 200
  end

  test "a safe run whose terminal persistence fails gets one restart, never an unbounded loop" do
    %{parent: parent, children: [failing, sibling], receipt: receipt} = frame_two()
    add_safe_step(failing)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [
      lifecycle_opts: [
        adapter: TerminalPersistenceFailureAdapter,
        failing_child_id: failing.id
      ]
    ]

    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    eventually(fn ->
      with {:ok, failed} <- Objectives.get_objective(failing.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        failed.status == "failed" and failed.run_attempt_count == 2 and
          failed.review_reason =~ "retry_exhausted" and completed.status == "completed" and
          joined.join_outcome == "partial"
      end
    end)

    Process.sleep(100)
    assert {:ok, failed} = Objectives.get_objective(failing.id)
    assert failed.run_attempt_count == 2
    assert Enum.count(Objectives.list_events(failing.id), &(&1.kind == "run_started")) == 2
  end

  test "a pending steer after exhausted safe work is preserved without a third execution" do
    %{parent: parent, children: [crashing, sibling], receipt: receipt} = frame_two()
    add_safe_step(crashing)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    crashing_id = crashing.id
    first_pid = await_paused_run(crashing_id)
    Process.exit(first_pid, :kill)

    second_pid = await_paused_run(crashing_id)
    directive = "replace the exhausted task without replaying its earlier effect"
    assert {:ok, _steer} = Steering.steer("alice", crashing_id, directive)
    Process.exit(second_pid, :kill)

    release_child_when_paused(sibling.id)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(crashing_id) do
        blocked.status == "blocked" and blocked.run_attempt_count == 2 and
          blocked.title == directive and blocked.review_reason =~ "uncertain_effect"
      end
    end)

    refute_receive {:run_operation, ^crashing_id, :execute, _pid}, 200

    events = Objectives.list_events(crashing_id)
    assert Enum.count(events, &(&1.kind == "run_started")) == 2
    assert Enum.count(events, &(&1.kind == "steer_applied")) == 1
    assert Enum.count(events, &(&1.kind == "run_blocked")) == 1
  end

  test "a transient post-steer review write retains the blocked recovery intent" do
    %{parent: parent, children: [crashing, sibling], receipt: receipt} = frame_two()
    add_safe_step(crashing)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    {:ok, transition_attempts} = Agent.start_link(fn -> 0 end)

    recovery_transaction_hook = fn child ->
      if child.id == crashing.id do
        case Agent.get_and_update(transition_attempts, &{&1 + 1, &1 + 1}) do
          1 -> {:error, %Exqlite.Error{message: "database is locked"}}
          _later -> :ok
        end
      else
        :ok
      end
    end

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]

    assert {:ok, _coordinator} =
             Scheduler.start_fanout(parent.id,
               run_opts: run_opts,
               recovery_transaction_hook: recovery_transaction_hook
             )

    crashing_id = crashing.id
    first_pid = await_paused_run(crashing_id)
    Process.exit(first_pid, :kill)

    second_pid = await_paused_run(crashing_id)
    directive = "preserve this steered task for explicit review"
    assert {:ok, _steer} = Steering.steer("alice", crashing_id, directive)
    Process.exit(second_pid, :kill)
    release_child_when_paused(sibling.id)

    eventually(fn ->
      with {:ok, blocked} <- Objectives.get_objective(crashing_id) do
        blocked.status == "blocked" and blocked.run_attempt_count == 2 and
          blocked.title == directive and blocked.review_reason =~ "uncertain_effect"
      end
    end)

    refute_receive {:run_operation, ^crashing_id, :execute, _pid}, 200
    assert Agent.get(transition_attempts, & &1) == 2
  end

  test "a transient uncertain-effect park failure retries persistence without replaying work" do
    %{parent: parent, children: [uncertain, sibling], receipt: receipt} = frame_two()
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    {:ok, transition_attempts} = Agent.start_link(fn -> 0 end)

    recovery_transaction_hook = fn child ->
      if child.id == uncertain.id do
        case Agent.get_and_update(transition_attempts, &{&1 + 1, &1 + 1}) do
          1 -> {:error, %Exqlite.Error{message: "database is locked"}}
          _later -> :ok
        end
      else
        :ok
      end
    end

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]

    assert {:ok, _coordinator} =
             Scheduler.start_fanout(parent.id,
               run_opts: run_opts,
               recovery_transaction_hook: recovery_transaction_hook
             )

    uncertain_id = uncertain.id
    uncertain_pid = await_paused_run(uncertain_id)
    Process.exit(uncertain_pid, :kill)
    release_child_when_paused(sibling.id)

    eventually(fn ->
      with {:ok, parked} <- Objectives.get_objective(uncertain_id) do
        parked.status == "blocked" and parked.run_attempt_count == 1 and
          parked.review_reason =~ "uncertain_effect"
      end
    end)

    refute_receive {:run_operation, ^uncertain_id, :execute, _pid}, 200
    assert Agent.get(transition_attempts, & &1) == 2
  end

  test "a transient exhausted-retry failure persists terminal state without a third attempt" do
    %{parent: parent, children: [crashing, sibling], receipt: receipt} = frame_two()
    add_safe_step(crashing)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    {:ok, transition_attempts} = Agent.start_link(fn -> 0 end)

    recovery_transaction_hook = fn child ->
      if child.id == crashing.id do
        case Agent.get_and_update(transition_attempts, &{&1 + 1, &1 + 1}) do
          1 -> {:error, %Exqlite.Error{message: "database is busy"}}
          _later -> :ok
        end
      else
        :ok
      end
    end

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]

    assert {:ok, _coordinator} =
             Scheduler.start_fanout(parent.id,
               run_opts: run_opts,
               recovery_transaction_hook: recovery_transaction_hook
             )

    crashing_id = crashing.id
    first_pid = await_paused_run(crashing_id)
    Process.exit(first_pid, :kill)
    second_pid = await_paused_run(crashing_id)
    Process.exit(second_pid, :kill)
    release_child_when_paused(sibling.id)

    eventually(fn ->
      with {:ok, failed} <- Objectives.get_objective(crashing_id) do
        failed.status == "failed" and failed.run_attempt_count == 2 and
          failed.review_reason =~ "retry_exhausted"
      end
    end)

    refute_receive {:run_operation, ^crashing_id, :execute, _pid}, 200
    assert Agent.get(transition_attempts, & &1) == 2
    assert Enum.count(Objectives.list_events(crashing_id), &(&1.kind == "run_started")) == 2
  end

  test "a permanent recovery transition error stays held and never becomes an execution grant" do
    %{parent: parent, children: [uncertain, sibling], receipt: receipt} = frame_two()
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    {:ok, transition_attempts} = Agent.start_link(fn -> 0 end)

    recovery_transaction_hook = fn child ->
      if child.id == uncertain.id do
        Agent.update(transition_attempts, &(&1 + 1))
        {:error, :injected_permanent_recovery_failure}
      else
        :ok
      end
    end

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]

    assert {:ok, coordinator} =
             Scheduler.start_fanout(parent.id,
               run_opts: run_opts,
               recovery_transaction_hook: recovery_transaction_hook
             )

    uncertain_id = uncertain.id
    uncertain_pid = await_paused_run(uncertain_id)
    Process.exit(uncertain_pid, :kill)
    release_child_when_paused(sibling.id)

    eventually(fn -> Agent.get(transition_attempts, & &1) == 1 end)
    Process.sleep(150)

    assert Process.alive?(coordinator)

    assert {:ok, %{status: "running", run_attempt_count: 1}} =
             Objectives.get_objective(uncertain_id)

    assert Agent.get(transition_attempts, & &1) == 1
    refute_receive {:run_operation, ^uncertain_id, :execute, _pid}, 200
  end

  test "a transient worker start failure retries the same child and joins exactly once" do
    %{parent: parent, children: [failing, sibling], receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    {:ok, attempts} = Agent.start_link(fn -> %{} end)

    run_starter = fn {run_server, opts} ->
      child_id = Keyword.fetch!(opts, :child_id)

      attempt =
        Agent.get_and_update(attempts, fn counts ->
          attempt = Map.get(counts, child_id, 0) + 1
          {attempt, Map.put(counts, child_id, attempt)}
        end)

      if child_id == failing.id and attempt == 1 do
        {:error, :injected_transient_start_failure}
      else
        DynamicSupervisor.start_child(
          AllbertAssist.Objectives.Runs.Supervisor,
          {run_server, opts}
        )
      end
    end

    assert {:ok, _coordinator} =
             Scheduler.start_fanout(parent.id,
               run_starter: run_starter,
               run_opts: [lifecycle_opts: [adapter: FreshChildAdapter]]
             )

    eventually(fn ->
      with {:ok, retried} <- Objectives.get_objective(failing.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        retried.status == "completed" and retried.run_attempt_count == 1 and
          completed.status == "completed" and joined.join_outcome == "success"
      end
    end)

    assert Agent.get(attempts, &Map.fetch!(&1, failing.id)) == 2
    assert Agent.get(attempts, &Map.fetch!(&1, sibling.id)) == 1
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "transient database failures before run_started retry without uncertain-effect parking" do
    %{parent: parent, children: [contended, sibling], receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    {:ok, attempts} = Agent.start_link(fn -> %{} end)
    test_pid = self()

    run_starter = fn {run_server, opts} ->
      child_id = Keyword.fetch!(opts, :child_id)

      attempt =
        Agent.get_and_update(attempts, fn counts ->
          attempt = Map.get(counts, child_id, 0) + 1
          {attempt, Map.put(counts, child_id, attempt)}
        end)

      if child_id == contended.id and attempt in [1, 2] do
        coordinator = Keyword.fetch!(opts, :coordinator)

        reason =
          if attempt == 1 do
            %Exqlite.Error{
              message: "database is locked",
              statement: "BEGIN IMMEDIATE TRANSACTION"
            }
          else
            %DBConnection.ConnectionError{
              message: "connection is closed because of an error, disconnect or timeout",
              severity: :error,
              reason: :error
            }
          end

        pid =
          if attempt == 1 do
            spawn(fn ->
              test_ref = Process.monitor(test_pid)
              Process.sleep(25)
              send(coordinator, {:run_terminal, child_id, {:error, reason}})

              receive do
                :stop -> :ok
                {:DOWN, ^test_ref, :process, ^test_pid, _reason} -> :ok
              end
            end)
          else
            spawn(fn ->
              Process.sleep(25)
              exit({:database_start_failure, reason})
            end)
          end

        {:ok, pid}
      else
        DynamicSupervisor.start_child(
          AllbertAssist.Objectives.Runs.Supervisor,
          {run_server, opts}
        )
      end
    end

    assert {:ok, _coordinator} =
             Scheduler.start_fanout(parent.id,
               run_starter: run_starter,
               run_opts: [lifecycle_opts: [adapter: FreshChildAdapter]]
             )

    eventually(fn ->
      with {:ok, retried} <- Objectives.get_objective(contended.id),
           {:ok, completed} <- Objectives.get_objective(sibling.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        retried.status == "completed" and retried.run_attempt_count == 1 and
          completed.status == "completed" and joined.join_outcome == "success"
      end
    end)

    assert Agent.get(attempts, &Map.fetch!(&1, contended.id)) == 3
    refute Enum.any?(Objectives.list_events(contended.id), &(&1.kind == "run_blocked"))
    assert Enum.count(Objectives.list_events(contended.id), &(&1.kind == "run_started")) == 1
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1

    eventually(fn ->
      Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent.id}) == []
    end)

    Process.sleep(100)
  end

  test "a successful worker start clears its pre-effect database retry history" do
    %{parent: parent, children: [contended, sibling], receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    {:ok, attempts} = Agent.start_link(fn -> %{} end)
    test_pid = self()

    run_starter = fn {run_server, opts} ->
      child_id = Keyword.fetch!(opts, :child_id)

      attempt =
        Agent.get_and_update(attempts, fn counts ->
          attempt = Map.get(counts, child_id, 0) + 1
          {attempt, Map.put(counts, child_id, attempt)}
        end)

      if child_id == contended.id and attempt == 1 do
        coordinator = Keyword.fetch!(opts, :coordinator)

        pid =
          spawn(fn ->
            test_ref = Process.monitor(test_pid)
            Process.sleep(25)

            send(
              coordinator,
              {:run_terminal, child_id, {:error, %Exqlite.Error{message: "database is locked"}}}
            )

            receive do
              :stop -> :ok
              {:DOWN, ^test_ref, :process, ^test_pid, _reason} -> :ok
            end
          end)

        {:ok, pid}
      else
        DynamicSupervisor.start_child(
          AllbertAssist.Objectives.Runs.Supervisor,
          {run_server, opts}
        )
      end
    end

    assert {:ok, coordinator} =
             Scheduler.start_fanout(parent.id,
               run_starter: run_starter,
               run_opts: [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
             )

    contended_pid = await_paused_run(contended.id)
    refute Map.has_key?(:sys.get_state(coordinator).pre_effect_retries, contended.id)

    send(contended_pid, :continue)
    release_child_when_paused(sibling.id)

    eventually(fn ->
      with {:ok, joined} <- Objectives.get_objective(parent.id) do
        joined.status == "completed" and joined.join_outcome == "success"
      end
    end)
  end

  test "supervised cancellation is terminal before recovery and join" do
    assert {:ok, _setting} =
             Settings.put("execution.cancel.grace_ms", 500, %{audit?: false})

    %{parent: parent, children: [cancelled, sibling], receipt: receipt} = frame_two()
    cancelled_id = cancelled.id
    add_safe_step(cancelled)
    add_safe_step(sibling)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    cancelled_pid = await_paused_run(cancelled.id)
    sibling_pid = await_paused_run(sibling.id)

    cancel_task =
      Task.async(fn ->
        Runner.run(
          "cancel_objective_run",
          %{objective_id: cancelled.id, reason: "operator skipped child"},
          %{user_id: "alice", channel: "test"}
        )
      end)

    eventually(fn ->
      match?(
        {:ok, %{status: "blocked", review_reason: "cancellation_requested"}},
        Objectives.get_objective(cancelled.id)
      )
    end)

    assert {:ok, response} = Task.await(cancel_task, 2_000)

    assert response.status == :cancelled, inspect(response)
    assert response.cancellation_tier == :supervised
    refute Process.alive?(cancelled_pid)
    send(sibling_pid, :continue)

    eventually(fn ->
      with {:ok, child} <- Objectives.get_objective(cancelled.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        child.status == "cancelled" and child.run_attempt_count == 1 and
          joined.join_outcome == "partial"
      end
    end)

    assert {:ok, stable} = Objectives.get_objective(cancelled.id)
    assert stable.review_reason == "operator skipped child"
    stable_updated_at = stable.updated_at
    Process.sleep(200)
    assert {:ok, unchanged} = Objectives.get_objective(cancelled.id)
    assert unchanged.status == "cancelled"
    assert unchanged.run_attempt_count == 1
    assert unchanged.updated_at == stable_updated_at
    assert Enum.count(Objectives.list_events(cancelled.id), &(&1.kind == "run_started")) == 1
    refute_receive {:run_operation, ^cancelled_id, :execute, _pid}, 200
  end

  test "parent cancellation succeeds when completed and active children coexist" do
    assert {:ok, _setting} =
             Settings.put("execution.cancel.grace_ms", 100, %{audit?: false})

    %{parent: parent, children: [completed, active], receipt: receipt} = frame_two()
    add_safe_step(completed)
    add_safe_step(active)
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    run_opts = [lifecycle_opts: [adapter: PausingAdapter, test_pid: self()]]
    assert {:ok, _coordinator} = Scheduler.start_fanout(parent.id, run_opts: run_opts)

    completed_pid = await_paused_run(completed.id)
    _active_pid = await_paused_run(active.id)
    send(completed_pid, :continue)

    eventually(fn ->
      match?({:ok, %{status: "completed"}}, Objectives.get_objective(completed.id))
    end)

    assert {:ok, response} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: parent.id, reason: "stop remaining work"},
               %{user_id: "alice", channel: "test"}
             )

    assert response.status == :cancelled, inspect(response)

    eventually(fn ->
      with {:ok, completed_child} <- Objectives.get_objective(completed.id),
           {:ok, cancelled_child} <- Objectives.get_objective(active.id),
           {:ok, joined} <- Objectives.get_objective(parent.id) do
        completed_child.status == "completed" and cancelled_child.status == "cancelled" and
          joined.status == "completed" and joined.join_outcome == "partial"
      end
    end)
  end

  test "parent cancellation reports finalizing without mutating a recovering fan-out" do
    %{parent: parent, children: children, receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    # Reproduce a pre-M12.15 crash orphan without using a production writer.
    assert {2, _rows} =
             Objective
             |> where([objective], objective.id in ^Enum.map(children, & &1.id))
             |> Repo.update_all(
               set: [
                 status: "completed",
                 last_observation_summary: "durable result",
                 completed_at: DateTime.utc_now()
               ]
             )

    assert Fanout.parent_projection(parent).phase == :recovering

    assert {:ok, response} =
             Runner.run(
               "cancel_objective_run",
               %{objective_id: parent.id, reason: "cancel stale UI state"},
               %{user_id: "alice", channel: "test"}
             )

    assert response.status == :finalizing
    assert response.message =~ "no active tasks"

    eventually(fn -> Fanout.parent_projection(parent).phase == :recovering end)

    for objective <- [parent | children] do
      kinds = Enum.map(Objectives.list_events(objective.id), & &1.kind)
      refute "cancellation_requested" in kinds
      refute "run_cancelled" in kinds
    end
  end

  test "scheduler rehydration preserves the global capacity barrier and releases an exited run" do
    %{parent: first_parent, children: [first_child | _], receipt: first_receipt} = frame_two()
    %{parent: second_parent, children: [second_child | _], receipt: second_receipt} = frame_two()

    first_coordinator = start_registry_fixture({:fanout, first_parent.id})
    second_coordinator = start_registry_fixture({:fanout, second_parent.id})
    first_run = start_registry_fixture({:run, first_child.id})

    assert :ok = Fanout.acknowledge_start(first_receipt, %{user_id: "alice"})
    assert :ok = Fanout.acknowledge_start(second_receipt, %{user_id: "alice"})

    scheduler =
      start_isolated_scheduler(
        rehydrate?: true,
        max_concurrent_runs_global: 1,
        max_concurrent_runs_per_fanout: 1
      )

    eventually(fn ->
      snapshot = Scheduler.snapshot(scheduler)
      snapshot.active == %{first_child.id => first_parent.id}
    end)

    assert :queued =
             Scheduler.request_slot(
               second_parent.id,
               second_child.id,
               self(),
               scheduler
             )

    Process.exit(first_run, :kill)

    assert_receive {:run_grant, second_child_id}, 2_000
    assert second_child_id == second_child.id

    eventually(fn ->
      snapshot = Scheduler.snapshot(scheduler)
      snapshot.active == %{second_child.id => second_parent.id}
    end)

    assert :ok = Scheduler.finish_fanout(first_parent.id, scheduler)
    assert :ok = Scheduler.finish_fanout(second_parent.id, scheduler)
    stop_registry_fixture(first_coordinator)
    stop_registry_fixture(second_coordinator)
  end

  test "a dead coordinator cannot leave stale queued grants behind" do
    scheduler =
      start_isolated_scheduler(
        rehydrate?: false,
        max_concurrent_runs_global: 1,
        max_concurrent_runs_per_fanout: 1
      )

    coordinator = spawn(fn -> receive do: (:stop -> :ok) end)
    on_exit(fn -> stop_registry_fixture(coordinator) end)

    assert :granted = Scheduler.request_slot("active-parent", "active-child", self(), scheduler)
    Scheduler.track_coordinator("queued-parent", coordinator, scheduler)
    _ = Scheduler.snapshot(scheduler)

    assert :queued =
             Scheduler.request_slot(
               "queued-parent",
               "queued-child",
               coordinator,
               scheduler
             )

    Process.exit(coordinator, :kill)

    eventually(fn ->
      snapshot = Scheduler.snapshot(scheduler)
      snapshot.waiting == %{} and snapshot.rotation == []
    end)

    Scheduler.release("active-child", scheduler)
    refute_receive {:run_grant, "queued-child"}, 100
  end

  test "live coordinator recovery repairs an all-terminal open parent" do
    %{parent: parent, children: children, receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    for child <- children do
      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   last_observation_summary: "historical result",
                   completed_at: DateTime.utc_now()
                 ]
               )
    end

    tracked = spawn(fn -> receive do: (:stop -> :ok) end)
    Scheduler.track_coordinator(parent.id, tracked)
    _ = Scheduler.snapshot()
    Process.exit(tracked, :kill)

    eventually(fn ->
      with {:ok, joined} <- Objectives.get_objective(parent.id) do
        joined.status == "completed" and joined.join_outcome == "success" and
          joined.report_composition_state == "queued" and
          joined.report_delivery_state == "not_ready"
      end
    end)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "a durable mutation can safely request recovery while the scheduler is unavailable" do
    assert :ok = Scheduler.wake_parent("fanout-durable-fixture", :missing_fanout_scheduler)
  end

  test "join reconciliation keeps retrying with backoff until durable fan-in succeeds" do
    %{parent: parent, children: children, receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    for child <- children do
      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   last_observation_summary: "durable result",
                   completed_at: DateTime.utc_now()
                 ]
               )
    end

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    join_reconciler = fn parent_id, opts ->
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)

      if attempt < 2,
        do: {:error, :injected_join_failure},
        else: Fanout.reconcile_parent(parent_id, opts)
    end

    assert {:ok, _coordinator} =
             Scheduler.start_fanout(parent.id, join_reconciler: join_reconciler)

    eventually(fn ->
      projection = Fanout.parent_projection(parent)

      projection.phase == :recovering and
        projection.parent.report_composition_state == "queued" and
        projection.parent.report_delivery_state == "not_ready"
    end)

    assert Agent.get(attempts, & &1) >= 3
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "join reconciliation contains transient database exceptions and retries" do
    %{parent: parent, children: children, receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    for child <- children do
      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   last_observation_summary: "durable result",
                   completed_at: DateTime.utc_now()
                 ]
               )
    end

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    join_reconciler = fn parent_id, opts ->
      attempt = Agent.get_and_update(attempts, fn count -> {count, count + 1} end)

      case attempt do
        0 -> raise %DBConnection.ConnectionError{message: "injected connection failure"}
        1 -> raise %Exqlite.Error{message: "Database is busy"}
        2 -> exit({:shutdown, %DBConnection.ConnectionError{message: "injected connection exit"}})
        _attempt -> Fanout.reconcile_parent(parent_id, opts)
      end
    end

    assert {:ok, coordinator} =
             Scheduler.start_fanout(parent.id, join_reconciler: join_reconciler)

    monitor_ref = Process.monitor(coordinator)

    eventually(fn ->
      projection = Fanout.parent_projection(parent)

      projection.phase == :recovering and
        projection.parent.report_composition_state == "queued" and
        projection.parent.report_delivery_state == "not_ready"
    end)

    assert Agent.get(attempts, & &1) >= 4
    assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator, :normal}, 1_000
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "join reconciliation keeps programming errors crash-visible" do
    %{parent: parent, children: children, receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    for child <- children do
      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   last_observation_summary: "durable result",
                   completed_at: DateTime.utc_now()
                 ]
               )
    end

    {:ok, attempts} = Agent.start_link(fn -> 0 end)

    join_reconciler = fn _parent_id, _opts ->
      Agent.update(attempts, &(&1 + 1))
      raise "injected programming error"
    end

    assert {:ok, coordinator} =
             Scheduler.start_fanout(parent.id, join_reconciler: join_reconciler)

    monitor_ref = Process.monitor(coordinator)

    assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator,
                    {%RuntimeError{message: "injected programming error"}, _stacktrace}},
                   500

    assert Agent.get(attempts, & &1) == 1

    eventually(fn ->
      projection = Fanout.parent_projection(parent)

      projection.phase == :recovering and
        projection.parent.report_composition_state == "queued" and
        projection.parent.report_delivery_state == "not_ready" and
        Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent.id}) == []
    end)
  end

  test "persistent coordinator crashes retain scheduler recovery backoff" do
    %{parent: parent, receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    test_pid = self()

    coordinator_starter = fn _opts ->
      scheduler_pid = self()

      pid =
        spawn(fn ->
          scheduler_ref = Process.monitor(scheduler_pid)

          receive do
            :stop -> :ok
            {:DOWN, ^scheduler_ref, :process, ^scheduler_pid, _reason} -> :ok
          end
        end)

      send(test_pid, {:recovery_candidate, pid})
      {:ok, pid}
    end

    scheduler =
      start_isolated_scheduler(
        rehydrate?: false,
        coordinator_starter: coordinator_starter
      )

    initial = spawn(fn -> receive do: (:stop -> :ok) end)
    Scheduler.track_coordinator(parent.id, initial, scheduler)
    _snapshot = Scheduler.snapshot(scheduler)
    Process.exit(initial, :kill)

    for _attempt <- 1..2 do
      assert_receive {:recovery_candidate, candidate}, 1_000
      Process.exit(candidate, :kill)
    end

    eventually(fn ->
      state = :sys.get_state(scheduler)
      Map.get(state.recovery_attempts, parent.id, 0) >= 3
    end)

    assert_receive {:recovery_candidate, stable_candidate}, 1_000
    Scheduler.recovery_stable(parent.id, stable_candidate, scheduler)

    eventually(fn ->
      state = :sys.get_state(scheduler)
      not Map.has_key?(state.recovery_attempts, parent.id)
    end)

    send(stable_candidate, :stop)
  end

  test "a coordinator retires when its durable parent no longer exists" do
    %{parent: parent, children: children, receipt: receipt} = frame_two()
    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    for child <- children do
      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   last_observation_summary: "durable result",
                   completed_at: DateTime.utc_now()
                 ]
               )
    end

    test_pid = self()

    missing_parent = fn reconciled_parent_id, _opts ->
      send(test_pid, {:missing_parent_reconciled, reconciled_parent_id})
      {:error, :fanout_parent_not_found}
    end

    assert {:ok, coordinator} =
             Scheduler.start_fanout(parent.id, join_reconciler: missing_parent)

    monitor_ref = Process.monitor(coordinator)

    assert_receive {:missing_parent_reconciled, parent_id}, 1_000
    assert parent_id == parent.id
    assert_receive {:DOWN, ^monitor_ref, :process, ^coordinator, :normal}, 500
    refute_receive {:missing_parent_reconciled, ^parent_id}, 100
    assert Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:fanout, parent.id}) == []
    assert Process.alive?(Process.whereis(Scheduler))
    assert %{active: %{}, waiting: %{}, rotation: []} = Scheduler.snapshot()
  end

  test "boot reconciliation resumes safe work and parks unknown in-flight work" do
    %{parent: parent, children: [safe, unknown], receipt: receipt} = frame_two()
    add_safe_step(safe)

    for child <- [safe, unknown] do
      force_historical_active_state(child, "running", 1)
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

  defp frame_two_with_budget do
    original = unique("Parallel frozen-budget request")

    plan_children = [
      %{
        title: unique("first"),
        objective: "Complete the first safe recovery fixture",
        expected_result: "The first fixture completes"
      },
      %{
        title: unique("second"),
        objective: "Complete the second safe recovery fixture",
        expected_result: "The second fixture completes"
      }
    ]

    assert {:ok, compiled} = FanoutPlan.compile(original, plan_children, source: :model)
    assert {:ok, budget} = Budget.resolve(2, 1)

    provenance =
      compiled
      |> FanoutPlan.provenance()
      |> Map.put("budget", budget)
      |> Map.put("deadline_unix_ms", System.system_time(:millisecond) + 60_000)

    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 title: unique("parent"),
                 objective: original,
                 proposer_hint: %{"fanout_plan" => provenance}
               },
               FanoutPlan.child_attrs(compiled)
             )

    on_exit(fn -> stop_fanout_processes(parent.id, Enum.map(children, & &1.id)) end)

    %{parent: parent, children: children, receipt: receipt}
  end

  defp stop_fanout_processes(parent_id, child_ids) do
    if Process.whereis(AllbertAssist.Objectives.Runs.Scheduler),
      do: Scheduler.finish_fanout(parent_id)

    keys = [{:fanout, parent_id} | Enum.map(child_ids, &{:run, &1})]

    Enum.each(keys, &terminate_registered_process/1)
  end

  defp start_isolated_scheduler(opts) do
    name = :"fanout_scheduler_test_#{System.unique_integer([:positive])}"

    start_supervised!(
      Supervisor.child_spec(
        {Scheduler, Keyword.put(opts, :name, name)},
        id: name
      )
    )

    name
  end

  defp start_registry_fixture(key) do
    owner = self()

    pid =
      spawn(fn ->
        result = Registry.register(AllbertAssist.Objectives.Runs.Registry, key, nil)
        send(owner, {:registry_fixture_started, self(), result})
        registry_fixture_loop()
      end)

    assert_receive {:registry_fixture_started, ^pid, {:ok, _owner}}, 1_000
    on_exit(fn -> stop_registry_fixture(pid) end)
    pid
  end

  defp stop_registry_fixture(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, :stop)

      receive do
        {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
      after
        500 -> Process.demonitor(ref, [:flush])
      end
    end
  end

  defp registry_fixture_loop do
    receive do
      :stop -> :ok
      _message -> registry_fixture_loop()
    end
  end

  defp force_historical_active_state(child, status, attempt) do
    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^child.id)
             |> Repo.update_all(
               set: [status: status, run_attempt_count: attempt, updated_at: DateTime.utc_now()]
             )

    :ok
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

  defp add_safe_step(child), do: add_action_step(child, "list_objectives")

  defp add_action_step(child, action) do
    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: child.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: action,
               action_params: %{user_id: child.user_id}
             })

    step
  end

  defp create_child_confirmation(child, step, opts \\ []) do
    permission = Keyword.get(opts, :permission, :read_only)
    execution_mode = Keyword.get(opts, :execution_mode, :read_only)
    decision = Keyword.get(opts, :decision, :allowed)

    Confirmations.create(
      %{
        origin: %{actor: child.user_id, channel: "test"},
        target_action: %{name: step.candidate_action},
        target_permission: permission,
        target_execution_mode: execution_mode,
        security_decision: %{permission: permission, decision: decision},
        params_summary: %{
          objective_id: child.id,
          step_id: step.id,
          objective_title: child.title,
          objective_status: child.status
        },
        resume_params_ref: %{}
      },
      %{
        user_id: child.user_id,
        objective_id: child.id,
        step_id: step.id,
        parent_objective_id: child.parent_objective_id,
        selected_action: step.candidate_action
      }
    )
  end

  defp rewrite_as_candidate_unversioned!(confirmation) do
    legacy =
      confirmation
      |> Map.drop(["objective_binding_version", "objective_binding_kind"])
      |> Map.update!("origin", &Map.delete(&1, "user_id"))

    write_confirmation!(legacy)

    assert {:ok, ^legacy} = Confirmations.read(confirmation["id"])
    legacy
  end

  defp rewrite_as_provenance_free_unversioned!(confirmation) do
    legacy =
      confirmation
      |> Map.drop([
        "objective_binding_version",
        "objective_binding_kind",
        "objective_id",
        "step_id"
      ])
      |> Map.update!("origin", fn origin ->
        Map.drop(origin, ["objective_id", "step_id", "parent_objective_id"])
      end)

    write_confirmation!(legacy)

    assert {:ok, ^legacy} = Confirmations.read(confirmation["id"])
    legacy
  end

  defp write_confirmation!(confirmation) do
    confirmation["id"]
    |> ConfirmationPersistence.pending_path()
    |> File.write!(YamlCodec.encode!(confirmation))
  end

  defp command_success_count(workspace) do
    Audit.audit_root()
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.count(fn path ->
      content = File.read!(path)
      content =~ "event: succeeded" and content =~ "executable: pwd" and content =~ workspace
    end)
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
