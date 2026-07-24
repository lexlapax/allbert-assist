defmodule AllbertAssist.Objectives.Runs.LifecycleTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Lifecycle
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Steering
  alias AllbertAssist.Settings.Store

  @resolution_hook_key {Store, :resolution_hook}

  setup do
    on_exit(fn -> Process.delete(@resolution_hook_key) end)
    :ok
  end

  defmodule RecordingAdapter do
    def operation(operation, state, opts) do
      send(Keyword.fetch!(opts, :test_pid), {:operation, operation})
      {:ok, Map.put(state, operation, true)}
    end
  end

  defmodule ConfirmationAdapter do
    def operation(:propose, %{objective: objective} = state, _opts) do
      {:ok, Map.put(state, :step, List.last(AllbertAssist.Objectives.list_steps(objective.id)))}
    end

    def operation(:execute, state, _opts),
      do: {:blocked, {:needs_confirmation, "confirm-123"}, state}

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule SettingsMutationAdapter do
    alias AllbertAssist.Settings

    def operation(:propose, state, opts) do
      {:ok, value} = Settings.get("objectives.fanout.confirm_before_start")
      send(Keyword.fetch!(opts, :test_pid), {:propose_value, value})

      {:ok, _setting} =
        Settings.put("objectives.fanout.confirm_before_start", true, %{audit?: false})

      {:ok, state}
    end

    def operation(:evaluate, state, opts) do
      {:ok, value} = Settings.get("objectives.fanout.confirm_before_start")
      send(Keyword.fetch!(opts, :test_pid), {:evaluate_value, value})
      {:ok, state}
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule LongResultAdapter do
    def operation(:execute, state, _opts) do
      result = "AIzaSyDUMMYSecretShapeForAudit59 " <> String.duplicate("long result ", 300)
      {:ok, Map.put(state, :response, %{message: result})}
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule DelayedProposalAdapter do
    alias AllbertAssist.Objectives

    def operation(:propose, %{objective: objective} = state, opts) do
      proposal_count = Map.get(state, :proposal_count, 0) + 1

      if proposal_count == 1 do
        send(Keyword.fetch!(opts, :test_pid), {:proposal_in_flight, self()})

        receive do
          :finish_proposal -> :ok
        end
      end

      {:ok, step} =
        Objectives.create_step(%{
          objective_id: objective.id,
          kind: "action",
          status: "selected",
          stage: "propose_steps",
          candidate_action: "direct_answer",
          action_params: Jason.encode!(%{text: objective.objective})
        })

      {:ok, state |> Map.put(:step, step) |> Map.put(:proposal_count, proposal_count)}
    end

    def operation(:execute, %{step: step} = state, opts) do
      %{"text" => text} = Jason.decode!(step.action_params)
      send(Keyword.fetch!(opts, :test_pid), {:executed_objective, text})
      {:ok, Map.put(state, :response, %{message: "executed: #{text}"})}
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule DelayedExecutionAdapter do
    alias AllbertAssist.Objectives

    def operation(:propose, %{objective: objective} = state, opts) do
      {:ok, step} =
        Objectives.create_step(%{
          objective_id: objective.id,
          kind: "action",
          status: "selected",
          stage: "propose_steps",
          candidate_action: Keyword.get(opts, :candidate_action, "direct_answer"),
          action_params: Jason.encode!(%{text: objective.objective})
        })

      {:ok, Map.put(state, :step, step)}
    end

    def operation(:execute, %{step: step} = state, opts) do
      execution_count = Map.get(state, :execution_count, 0) + 1
      %{"text" => text} = Jason.decode!(step.action_params)

      if execution_count == 1 do
        send(Keyword.fetch!(opts, :test_pid), {:execution_in_flight, self(), text})

        receive do
          :finish_execution -> :ok
        end
      end

      send(Keyword.fetch!(opts, :test_pid), {:executed_objective, execution_count, text})

      {:ok,
       state
       |> Map.put(:execution_count, execution_count)
       |> Map.put(:response, %{message: "executed: #{text}"})}
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  test "runs the full lifecycle in order and persists attempt, progress, and completion" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Child",
               objective: "Do child work",
               fanout_role: "child"
             })

    assert {:ok, completed} =
             Lifecycle.run(child.id, adapter: RecordingAdapter, test_pid: self())

    assert completed.status == "completed"
    assert completed.run_attempt_count == 1

    for operation <- ~w[propose evaluate authorize execute observe advance]a do
      assert_received {:operation, ^operation}
    end

    assert Enum.map(Objectives.list_events(child.id), & &1.kind) == [
             "run_completed",
             "run_progress",
             "run_progress",
             "run_progress",
             "run_progress",
             "run_progress",
             "run_progress",
             "run_started"
           ]
  end

  test "a long successful result completes once with a redacted bounded durable summary" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Long child",
               objective: "Return a long result",
               fanout_role: "child"
             })

    assert {:ok, completed} = Lifecycle.run(child.id, adapter: LongResultAdapter)
    assert completed.status == "completed"
    assert completed.run_attempt_count == 1
    assert String.length(completed.last_observation_summary) <= 2_000
    assert completed.last_observation_summary =~ "[REDACTED]"
    refute completed.last_observation_summary =~ "DUMMYSecretShapeForAudit59"

    assert Enum.count(Objectives.list_events(child.id), &(&1.kind == "run_started")) == 1
    assert Enum.count(Objectives.list_events(child.id), &(&1.kind == "run_completed")) == 1
  end

  test "steering received during proposal replans before execution" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Original task",
               objective: "Explain OTP supervision as a restaurant",
               fanout_role: "child"
             })

    test_pid = self()

    task =
      Task.async(fn ->
        Lifecycle.run(child.id, adapter: DelayedProposalAdapter, test_pid: test_pid)
      end)

    assert_receive {:proposal_in_flight, runner}, 2_000

    directive = "Explain OTP supervision as a hospital"
    assert {:ok, _steer} = Steering.steer("alice", child.id, directive)
    send(runner, :finish_proposal)

    assert_receive {:executed_objective, ^directive}, 2_000
    assert {:ok, completed} = Task.await(task, 2_000)
    assert completed.title == directive
    assert completed.last_observation_summary == "executed: #{directive}"

    assert [superseded, effective] = Objectives.list_steps(child.id)
    assert superseded.status == "cancelled"
    assert Jason.decode!(effective.action_params) == %{"text" => directive}
  end

  test "steering received during a safe execution reruns from the effective objective" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Original task",
               objective: "Explain OTP supervision as a restaurant",
               fanout_role: "child"
             })

    test_pid = self()

    task =
      Task.async(fn ->
        Lifecycle.run(child.id, adapter: DelayedExecutionAdapter, test_pid: test_pid)
      end)

    assert_receive {:execution_in_flight, runner, "Explain OTP supervision as a restaurant"},
                   2_000

    directive = "Explain OTP supervision as a hospital"
    assert {:ok, _steer} = Steering.steer("alice", child.id, directive)
    send(runner, :finish_execution)

    assert_receive {:executed_objective, 1, "Explain OTP supervision as a restaurant"}, 2_000
    assert_receive {:executed_objective, 2, ^directive}, 2_000
    assert {:ok, completed} = Task.await(task, 2_000)
    assert completed.last_observation_summary == "executed: #{directive}"
    assert completed.run_attempt_count == 1
  end

  test "steering after a possibly effectful execution blocks instead of replaying it" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Original task",
               objective: "Send an operator message",
               fanout_role: "child"
             })

    test_pid = self()

    task =
      Task.async(fn ->
        Lifecycle.run(child.id,
          adapter: DelayedExecutionAdapter,
          candidate_action: "send_channel_message",
          test_pid: test_pid
        )
      end)

    assert_receive {:execution_in_flight, runner, "Send an operator message"}, 2_000

    assert {:ok, _steer} =
             Steering.steer(
               "alice",
               child.id,
               "Send a different message"
             )

    send(runner, :finish_execution)

    assert_receive {:executed_objective, 1, "Send an operator message"}, 2_000
    refute_receive {:executed_objective, 2, _text}, 200
    assert {:blocked, :steer_after_effect_requires_review} = Task.await(task, 2_000)

    assert {:ok, blocked} = Objectives.get_objective(child.id)
    assert blocked.status == "blocked"
    assert blocked.review_reason =~ "steer_after_effect_requires_review"
  end

  test "default adapter executes a registered action through Runner" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Child",
               objective: "List objectives",
               fanout_role: "child"
             })

    assert {:ok, _step} =
             Objectives.create_step(%{
               objective_id: child.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "list_objectives",
               action_params: %{user_id: "alice"}
             })

    assert {:ok, completed} = Lifecycle.run(child.id)
    assert completed.status == "completed"
    assert completed.last_observation_summary =~ "objective(s)"
  end

  test "missing proposal is filled by an inert intent decision before execution" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Child",
               objective: "Wait",
               fanout_role: "child"
             })

    assert {:ok, completed} = Lifecycle.run(child.id)
    assert completed.status == "completed"

    assert [%{candidate_action: "direct_answer", status: "selected"}] =
             Objectives.list_steps(child.id)
  end

  test "each operation receives its own resolved-settings pin" do
    counter = :counters.new(1, [])
    Process.put(@resolution_hook_key, fn -> :counters.add(counter, 1, 1) end)

    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Pinned child",
               objective: "Check settings boundaries",
               fanout_role: "child"
             })

    assert {:ok, _completed} =
             Lifecycle.run(child.id, adapter: RecordingAdapter, test_pid: self())

    assert :counters.get(counter, 1) == 6
  end

  test "a settings write becomes visible at the next operation, never mid-operation" do
    assert {:ok, _setting} =
             AllbertAssist.Settings.put("objectives.fanout.confirm_before_start", false, %{
               audit?: false
             })

    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Settings child",
               objective: "Observe operation pins",
               fanout_role: "child"
             })

    assert {:ok, _completed} =
             Lifecycle.run(child.id, adapter: SettingsMutationAdapter, test_pid: self())

    assert_received {:propose_value, false}
    assert_received {:evaluate_value, true}
  end

  test "a cooperative cancel token stops at the next operation boundary" do
    token = CancelToken.new()

    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Cancelled child",
               objective: "Stop safely",
               fanout_role: "child"
             })

    assert :ok = CancelToken.cancel(token)
    assert {:ok, cancelled} = Lifecycle.run(child.id, cancel_token: token)
    assert cancelled.status == "cancelled"
    assert Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_cancelled"))
  end

  test "confirmation parking persists the step receipt without blocking another run" do
    assert {:ok, child} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Confirmation child",
               objective: "Wait for authority",
               fanout_role: "child"
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: child.id,
               kind: "action",
               status: "selected",
               stage: "authorize_step",
               candidate_action: "list_objectives"
             })

    assert {:blocked, {:needs_confirmation, "confirm-123"}} =
             Lifecycle.run(child.id, adapter: ConfirmationAdapter)

    [parked] = Objectives.list_steps(child.id)
    assert parked.id == step.id
    assert parked.status == "blocked"
    assert parked.confirmation_id == "confirm-123"
  end
end
