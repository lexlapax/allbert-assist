defmodule AllbertAssist.Objectives.Runs.WorkerTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Runs.{Cancel, CancelToken, RunServer, Worker}
  alias AllbertAssist.Settings.Store

  @resolution_hook_key {Store, :resolution_hook}

  defmodule BlockingAnswerer do
    def answer(_text, context) do
      send(context.test_pid, {:blocking_answerer_started, self()})

      receive do
        :release_blocking_answerer ->
          {:ok, %{message: "released", diagnostic: %{status: :used}}}
      end
    end
  end

  defmodule SnapshotAnswerer do
    alias AllbertAssist.Settings

    def answer(_text, context) do
      {:ok, before_write} = Settings.get("objectives.fanout.confirm_before_start")
      send(context.test_pid, {:snapshot_before_write, self(), before_write})

      receive do
        :continue_snapshot_answerer -> :ok
      end

      {:ok, after_write} = Settings.get("objectives.fanout.confirm_before_start")
      send(context.test_pid, {:snapshot_after_write, self(), after_write})

      {:ok, %{message: "snapshot stayed stable", diagnostic: %{status: :used}}}
    end
  end

  defmodule RunServerBlockingAnswerer do
    def answer(_text, _context) do
      test_pid = Application.fetch_env!(:allbert_assist, :worker_run_server_test_pid)
      send(test_pid, {:run_server_answerer_started, self()})

      receive do
        :release_run_server_answerer ->
          {:ok, %{message: "released", diagnostic: %{status: :used}}}
      end
    end
  end

  defmodule ForbiddenAnswerer do
    def answer(_text, context) do
      send(context.test_pid, :unexpected_direct_answer_execution)
      {:ok, %{message: "must not execute", diagnostic: %{status: :used}}}
    end
  end

  setup do
    handler_id = {__MODULE__, self()}
    original_direct_answer_config = Application.get_env(:allbert_assist, DirectAnswer)

    on_exit(fn ->
      Process.delete(@resolution_hook_key)
      :telemetry.detach(handler_id)
      restore_env(DirectAnswer, original_direct_answer_config)
      Application.delete_env(:allbert_assist, :worker_run_server_test_pid)

      AllbertAssist.Settings.put(
        "intent.direct_answer_model_enabled",
        false,
        AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
      )

      AllbertAssist.Settings.put(
        "objectives.fanout.confirm_before_start",
        false,
        AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
          audit?: false
        })
      )
    end)

    :ok
  end

  test "a validated non-conversational action uses the ordinary Runner adapter" do
    context = %{user_id: "worker-user", operator_id: "worker-user", channel: "test"}

    assert {:ok, %{adapter: :ordinary, response: response, quality_receipt: nil}} =
             Worker.run("list_objectives", %{user_id: "worker-user"}, context)

    assert response.status == :completed
    assert response.message =~ "objective(s)"
    assert response.runner_metadata.action_name == "list_objectives"
  end

  test "the ordinary Adapter pins one resolved-settings snapshot around Runner" do
    counter = :counters.new(1, [])
    Process.put(@resolution_hook_key, fn -> :counters.add(counter, 1, 1) end)

    assert {:ok, %{adapter: :ordinary, response: %{status: :completed}, quality_receipt: nil}} =
             Worker.run(
               "list_objectives",
               %{user_id: "worker-user"},
               %{user_id: "worker-user", operator_id: "worker-user", channel: "test"}
             )

    assert :counters.get(counter, 1) == 1
  end

  test "a clean DirectAnswer action uses one temporary Jido worker and the same Runner" do
    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "intent.direct_answer_model_enabled",
               false,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      actor: "worker-user",
      channel: "test",
      surface: "test",
      objective_id: "objective-123",
      step_id: "step-123"
    }

    assert {:ok, %{adapter: :jido, response: response}} =
             Worker.run(
               "direct_answer",
               %{text: "Explain this supplied sentence: workers stay bounded."},
               context
             )

    assert response.status == :completed
    assert response.runner_metadata.action_name == "direct_answer"
    assert [%{name: "direct_answer", status: :completed}] = response.actions
  end

  test "an unknown action is rejected before any worker Adapter is selected" do
    assert {:error, {:unknown_action, "model-authored-worker"}} =
             Worker.run(
               "model-authored-worker",
               %{},
               %{user_id: "worker-user", operator_id: "worker-user", channel: "test"}
             )
  end

  test "manager and untrusted grounding cannot select an ordinary action at execution" do
    assert {:ok, budget} = Budget.resolve(2, 1)
    deadline = System.system_time(:millisecond) + 10_000

    base_context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      channel: "test",
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline,
      objective_run_attempt: 1
    }

    for source <- [:conversation_manager, :untrusted] do
      grounding = %{
        decision_text: nil,
        direct_answer_text: "Read-only child prose",
        action_text: nil,
        fanout_budget: budget,
        fanout_deadline_unix_ms: deadline,
        source: source
      }

      assert {:error, :fanout_child_action_not_authorized} =
               Worker.run(
                 "list_objectives",
                 %{user_id: "worker-user"},
                 Map.put(base_context, :fanout_grounding, grounding)
               )
    end
  end

  test "current grounded children cannot inherit the legacy nil or malformed budget allowance" do
    base_context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      channel: "test",
      objective_run_attempt: 1
    }

    for {budget, deadline} <- [
          {nil, nil},
          {%{"worker_attempts_per_child" => 2}, System.system_time(:millisecond) + 10_000},
          {%{"version" => 1}, "not-a-deadline"}
        ],
        source <- [:conversation_manager, :counted_protocol, :operator_steered, :untrusted] do
      grounding = %{
        decision_text: "List objectives",
        direct_answer_text: "List objectives",
        action_text: "List objectives",
        fanout_budget: budget,
        fanout_deadline_unix_ms: deadline,
        source: source
      }

      context =
        base_context
        |> Map.put(:fanout_budget, budget)
        |> Map.put(:fanout_deadline_unix_ms, deadline)
        |> Map.put(:fanout_grounding, grounding)

      assert {:error, :invalid_fanout_budget_snapshot} =
               Worker.run("direct_answer", %{text: "Do not run."}, context)
    end
  end

  test "a valid v1 budget preserves safe non-model work but cannot enter DirectAnswer" do
    budget = %{
      "version" => 1,
      "child_count" => 2,
      "manager_attempts" => 1,
      "worker_attempts_per_child" => 2,
      "configured_model_calls" => 40,
      "required_model_calls" => 10,
      "configured_output_tokens" => 24_000,
      "required_output_tokens" => 6_144,
      "max_elapsed_ms" => 300_000
    }

    deadline = System.system_time(:millisecond) + 10_000

    grounding = %{
      decision_text: "List objectives",
      direct_answer_text: "List objectives",
      action_text: "List objectives",
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline,
      source: :counted_protocol
    }

    context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      channel: "test",
      test_pid: self(),
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline,
      objective_run_attempt: 1,
      fanout_grounding: grounding
    }

    assert {:ok, %{adapter: :ordinary, response: %{status: :completed}}} =
             Worker.run("list_objectives", %{user_id: "worker-user"}, context)

    Application.put_env(:allbert_assist, DirectAnswer, answerer: ForbiddenAnswerer)

    assert {:error, :quality_protocol_upgrade_required} =
             Worker.run("direct_answer", %{text: "Do not invoke a provider."}, context)

    refute_receive :unexpected_direct_answer_execution
  end

  test "a cancelled RunServer token stops either Adapter before action execution" do
    token = CancelToken.new()
    :ok = CancelToken.cancel(token)

    context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      channel: "test",
      cancel_token: token
    }

    assert {:error, :cancelled} =
             Worker.run("list_objectives", %{user_id: "worker-user"}, context)

    assert {:error, :cancelled} =
             Worker.run("direct_answer", %{text: "Do not run this."}, context)
  end

  test "the Worker Interface enforces the frozen per-child attempts and plan deadline" do
    assert {:ok, budget} = Budget.resolve(2, 1)

    context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      channel: "test",
      fanout_budget: budget,
      fanout_deadline_unix_ms: System.system_time(:millisecond) + 10_000,
      objective_run_attempt: 3
    }

    assert {:error, :fanout_worker_attempt_budget_exhausted} =
             Worker.run("list_objectives", %{user_id: "worker-user"}, context)

    expired = %{
      context
      | objective_run_attempt: 1,
        fanout_deadline_unix_ms: System.system_time(:millisecond)
    }

    assert {:error, :fanout_plan_deadline_exhausted} =
             Worker.run("direct_answer", %{text: "Do not start."}, expired)
  end

  test "a v2 retry is admitted only for a registered retry-safe action" do
    assert {:ok, budget} = Budget.resolve(2, 1)

    context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      channel: "test",
      test_pid: self(),
      fanout_budget: budget,
      fanout_deadline_unix_ms: System.system_time(:millisecond) + 10_000,
      objective_run_attempt: 2
    }

    assert {:ok, %{adapter: :ordinary, response: %{status: :completed}}} =
             Worker.run("list_objectives", %{user_id: "worker-user"}, context)

    assert {:ok, %{retry_safety: :unknown}} = Registry.capability("cancel_objective")

    assert {:error, :fanout_worker_retry_unsafe} =
             Worker.run("cancel_objective", %{id: "must-not-run"}, context)

    Application.put_env(:allbert_assist, DirectAnswer, answerer: ForbiddenAnswerer)

    assert {:error, :fanout_worker_retry_unsafe} =
             Worker.run("direct_answer", %{text: "Do not invoke a provider."}, context)

    refute_receive :unexpected_direct_answer_execution
  end

  test "a budgetless compatibility retry still honors registered retry safety" do
    context = %{
      user_id: "worker-user",
      operator_id: "worker-user",
      channel: "test",
      test_pid: self(),
      objective_run_attempt: 2
    }

    assert {:ok, %{adapter: :ordinary, response: %{status: :completed}}} =
             Worker.run("list_objectives", %{user_id: "worker-user"}, context)

    assert {:ok, %{retry_safety: :unknown}} = Registry.capability("cancel_objective")

    assert {:error, :fanout_worker_retry_unsafe} =
             Worker.run("cancel_objective", %{id: "must-not-run"}, context)

    Application.put_env(:allbert_assist, DirectAnswer, answerer: ForbiddenAnswerer)

    assert {:error, :fanout_worker_retry_unsafe} =
             Worker.run("direct_answer", %{text: "Do not invoke a provider."}, context)

    refute_receive :unexpected_direct_answer_execution
  end

  test "a timed-out Jido worker is terminated before the Adapter returns" do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:allbert_assist, :objectives, :worker, :start],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:jido_worker_started, metadata.worker_pid})
        end,
        self()
      )

    Application.put_env(:allbert_assist, DirectAnswer, answerer: BlockingAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "intent.direct_answer_model_enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    test_pid = self()

    call =
      Task.async(fn ->
        Worker.run(
          "direct_answer",
          %{text: "This bounded worker must time out while executing."},
          %{
            user_id: "worker-user",
            operator_id: "worker-user",
            actor: "worker-user",
            channel: "test",
            objective_id: "timeout-objective",
            step_id: "timeout-step",
            test_pid: test_pid
          },
          worker_timeout_ms: 1_000
        )
      end)

    assert_receive {:jido_worker_started, worker}
    assert_receive {:blocking_answerer_started, answerer}, 900
    assert answerer == worker
    assert {:error, :worker_timeout} = Task.await(call, 2_000)
    refute Process.alive?(worker)
  end

  test "supervised RunServer cancellation leaves no linked Jido worker alive" do
    handler_id = {__MODULE__, self()}

    :ok =
      :telemetry.attach(
        handler_id,
        [:allbert_assist, :objectives, :worker, :start],
        fn _event, _measurements, metadata, test_pid ->
          send(test_pid, {:jido_worker_started, metadata.worker_pid})
        end,
        self()
      )

    Application.put_env(:allbert_assist, DirectAnswer, answerer: RunServerBlockingAnswerer)
    Application.put_env(:allbert_assist, :worker_run_server_test_pid, self())

    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "intent.direct_answer_model_enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, %{parent: parent, children: [child, _sibling]}} =
             Fanout.frame(
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 user_id: "worker-user",
                 title: "RunServer cancellation parent",
                 objective: "Run two bounded tasks"
               }),
               [
                 %{title: "Blocking child", objective: "Block in the provider"},
                 %{title: "Fixture sibling", objective: "Remain queued"}
               ]
             )

    assert {:ok, _step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "authorize_step",
                 candidate_action: "direct_answer",
                 action_params: %{text: child.objective}
               },
               AllbertAssist.TestSupport.ReadyEffectContext.context()
             )

    assert {:ok, run_server} =
             DynamicSupervisor.start_child(
               AllbertAssist.Objectives.Runs.Supervisor,
               {RunServer,
                child_id: child.id,
                parent_id: parent.id,
                coordinator: self(),
                lifecycle_opts: [worker_timeout_ms: 30_000]}
             )

    assert_receive {:jido_worker_started, worker}, 2_000
    assert_receive {:run_server_answerer_started, ^worker}, 2_000
    assert Process.alive?(run_server)
    assert Process.alive?(worker)

    run_monitor = Process.monitor(run_server)
    worker_monitor = Process.monitor(worker)

    assert {:ok, :supervised} = Cancel.cancel(child.id, grace_ms: 50)
    assert_receive {:DOWN, ^run_monitor, :process, ^run_server, _reason}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, _reason}, 1_000
    refute Process.alive?(run_server)
    refute Process.alive?(worker)
  end

  test "the Jido Adapter pins one settings snapshot around the complete Runner call" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: SnapshotAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "objectives.fanout.confirm_before_start",
               false,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "intent.direct_answer_model_enabled",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    test_pid = self()

    call =
      Task.async(fn ->
        Worker.run(
          "direct_answer",
          %{text: "Read one stable settings snapshot."},
          %{
            user_id: "worker-user",
            operator_id: "worker-user",
            actor: "worker-user",
            channel: "test",
            objective_id: "snapshot-objective",
            step_id: "snapshot-step",
            test_pid: test_pid
          },
          worker_timeout_ms: 5_000
        )
      end)

    assert_receive {:snapshot_before_write, worker, false}, 2_000

    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "objectives.fanout.confirm_before_start",
               true,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )

    send(worker, :continue_snapshot_answerer)
    assert_receive {:snapshot_after_write, ^worker, false}, 2_000

    assert {:ok, %{adapter: :jido, response: %{status: :completed}}} =
             Task.await(call, 2_000)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
