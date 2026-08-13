defmodule AllbertAssist.Objectives.Runs.LifecycleTest.EpochLifecycle do
  @moduledoc false

  alias AllbertAssist.Objectives.Runs.LifecycleTest.SameDigestReadiness
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Objectives.Lifecycle

  def run(child_id, opts \\ []) do
    with {:ok, epoch} <- EffectGuard.admit_ready() do
      Lifecycle.run(child_id, Keyword.put_new(opts, :allbert_pack_epoch, epoch))
    end
  end

  def reconcile_quality_protocol_upgrade(objective, opts \\ []) do
    with {:ok, epoch} <- EffectGuard.admit_ready() do
      Lifecycle.reconcile_quality_protocol_upgrade(
        objective,
        Keyword.put_new(opts, :allbert_pack_epoch, epoch)
      )
    end
  end
end

defmodule AllbertAssist.Objectives.Runs.LifecycleTest.EpochSteering do
  @moduledoc false

  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Objectives.Steering

  def steer(user_id, objective_id, directive) do
    with {:ok, epoch} <- EffectGuard.admit_ready() do
      Steering.steer(user_id, objective_id, directive, %{allbert_pack_epoch: epoch})
    end
  end

  def apply_pending(objective_id) do
    with {:ok, epoch} <- EffectGuard.admit_ready() do
      Steering.apply_pending(objective_id, %{allbert_pack_epoch: epoch})
    end
  end
end

defmodule AllbertAssist.Objectives.Runs.LifecycleTest.SameDigestReadiness do
  @moduledoc false

  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, opts)
  def replace(server), do: GenServer.call(server, :replace)

  @impl true
  def init(opts) do
    {:ok,
     %{
       active: spawn(fn -> Process.sleep(:infinity) end),
       replacement: spawn(fn -> Process.sleep(:infinity) end),
       replaced?: false,
       replace_after_status_calls: Keyword.get(opts, :replace_after_status_calls),
       status_calls: 0
     }}
  end

  @impl true
  def handle_call(:status, _from, %{active: active, replacement: replacement} = state) do
    status_calls = state.status_calls + 1

    replaced? =
      state.replaced? or
        (is_integer(state.replace_after_status_calls) and
           status_calls > state.replace_after_status_calls)

    barrier = if replaced?, do: replacement, else: active

    {:reply,
     {:ok,
      %{
        phase: :ready,
        barrier_pid: barrier,
        snapshot_digest: String.duplicate("a", 64),
        expected_ids: [],
        subscribed_ids: [],
        acked_ids: [],
        diagnostics: []
      }}, %{state | replaced?: replaced?, status_calls: status_calls}}
  end

  def handle_call(:replace, _from, state), do: {:reply, :ok, %{state | replaced?: true}}

  @impl true
  def terminate(_reason, %{active: active, replacement: replacement}) do
    Process.exit(active, :kill)
    Process.exit(replacement, :kill)
  end
end

defmodule AllbertAssist.Objectives.Runs.LifecycleTest.EpochObjectives do
  @moduledoc false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Pack.EffectGuard

  def get_objective(id), do: Objectives.get_objective(id)
  def list_events(id, opts \\ []), do: Objectives.list_events(id, opts)
  def list_steps(id), do: Objectives.list_steps(id)

  def fanout_confirmation_target(confirmation),
    do: Objectives.fanout_confirmation_target(confirmation)

  def fanout_confirmation_target(confirmation, opts),
    do: Objectives.fanout_confirmation_target(confirmation, opts)

  def create_step(attrs) do
    with {:ok, epoch} <- EffectGuard.admit_ready() do
      Objectives.create_step(attrs, %{allbert_pack_epoch: epoch})
    end
  end

  # Call sites that already hold an epoch pass their own context rather than
  # admitting a second one; without this arity they resolve against the wrapper
  # and raise UndefinedFunctionError.
  def create_step(attrs, context), do: Objectives.create_step(attrs, context)

  def transition_step(step, status, attrs) do
    with {:ok, epoch} <- EffectGuard.admit_ready() do
      Objectives.transition_step(step, status, attrs, %{allbert_pack_epoch: epoch})
    end
  end

  # Call sites that already hold an epoch pass their own context rather than
  # admitting a second one.
  def transition_step(step, status, attrs, context),
    do: Objectives.transition_step(step, status, attrs, context)
end

defmodule AllbertAssist.Objectives.Runs.LifecycleTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  @moduletag :db_serial

  import Ecto.Query

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ResumeParamsBinding
  alias AllbertAssist.Confirmations.Store.Persistence, as: ConfirmationPersistence
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Memory
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Objective
  # The real modules. This module aliases EpochLifecycle/EpochSteering AS
  # Lifecycle/Steering -- test doubles that shadow the short names on purpose --
  # so these two call sites spelled the real ones out in full. Naming them keeps
  # that intent visible instead of leaving it to whoever reads the long form.
  alias AllbertAssist.Objectives.Lifecycle, as: RealLifecycle
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Objectives.Runs.LifecycleTest.SameDigestReadiness
  alias AllbertAssist.Objectives.Runs.LifecycleTest.EpochLifecycle, as: Lifecycle
  alias AllbertAssist.Objectives.Runs.LifecycleTest.EpochObjectives, as: Objectives
  alias AllbertAssist.Objectives.Runs.LifecycleTest.EpochSteering, as: Steering
  alias AllbertAssist.Objectives.Runs.Worker.{Grounding, QualityPolicy, QualityReceipt}
  alias AllbertAssist.Objectives.Steering, as: RealSteering
  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Store
  alias AllbertAssist.Settings.YamlCodec
  alias AllbertAssist.TestSupport.ReadyEffectContext

  @resolution_hook_key {Store, :resolution_hook}
  @quoted_preference_prompt "What day and time does this sentence say I prefer for Project Juniper status summaries? I prefer Friday at 09:00, valid starting 2026-06-01. The validation marker is juniper-v13-primary. Answer in one sentence."
  @acknowledge_preference_prompt "In one sentence, acknowledge this stated preference: For Project Juniper validation, I prefer status summaries on Friday at 09:00, valid starting 2026-06-01. The validation marker is juniper-v13-primary."

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    settings_root =
      Path.join(
        System.tmp_dir!(),
        "allbert-lifecycle-settings-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: settings_root)

    on_exit(fn ->
      Process.delete(@resolution_hook_key)

      if original_settings_config do
        Application.put_env(:allbert_assist, Settings, original_settings_config)
      else
        Application.delete_env(:allbert_assist, Settings)
      end

      File.rm_rf!(settings_root)
    end)

    {:ok, settings_root: settings_root}
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
        Settings.put("objectives.fanout.confirm_before_start", true, %{
          audit?: false,
          allbert_pack_epoch: Keyword.fetch!(opts, :allbert_pack_epoch)
        })

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

  defmodule QualityCompletionAdapter do
    def operation(:propose, state, opts),
      do: {:ok, Map.put(state, :step, Keyword.fetch!(opts, :quality_step))}

    def operation(:execute, state, opts) do
      state =
        state
        |> Map.put(:response, %{message: Keyword.fetch!(opts, :quality_answer)})
        |> Map.put(:worker_adapter, :jido)

      next =
        case Keyword.fetch(opts, :quality_receipt) do
          {:ok, receipt} -> Map.put(state, :quality_receipt, receipt)
          :error -> state
        end

      {:ok, next}
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule ForeignStepAdapter do
    def operation(:propose, state, opts),
      do: {:ok, Map.put(state, :step, Keyword.fetch!(opts, :foreign_step))}

    def operation(:execute, state, _opts),
      do: {:ok, Map.put(state, :response, %{message: "foreign step must not commit"})}

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
        Objectives.create_step(
          %{
            objective_id: objective.id,
            kind: "action",
            status: "selected",
            stage: "propose_steps",
            candidate_action: "direct_answer",
            action_params: Jason.encode!(%{text: objective.objective})
          },
          %{allbert_pack_epoch: Keyword.fetch!(opts, :allbert_pack_epoch)}
        )

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
        Objectives.create_step(
          %{
            objective_id: objective.id,
            kind: "action",
            status: "selected",
            stage: "propose_steps",
            candidate_action: Keyword.get(opts, :candidate_action, "direct_answer"),
            action_params: Jason.encode!(%{text: objective.objective})
          },
          %{allbert_pack_epoch: Keyword.fetch!(opts, :allbert_pack_epoch)}
        )

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

  defmodule GroundedConfirmationAdapter do
    alias AllbertAssist.Actions.Registry
    alias AllbertAssist.Confirmations
    alias AllbertAssist.Objectives.Lifecycle.DefaultAdapter

    def owns_settings_pin?(operation), do: DefaultAdapter.owns_settings_pin?(operation)

    def operation(
          :execute,
          %{objective: objective, step: %{confirmation_id: nil} = step} = state,
          opts
        ) do
      params = Jason.decode!(step.action_params)
      {:ok, action_module} = Registry.resolve(step.candidate_action)

      {:ok, confirmation} =
        Confirmations.create(
          %{
            origin: %{actor: objective.user_id, channel: "test"},
            target_action: %{name: step.candidate_action, module: inspect(action_module)},
            target_permission: :read_only,
            target_execution_mode: :read_only,
            security_decision: %{permission: :read_only, decision: :needs_confirmation},
            params_summary: %{objective_id: objective.id, step_id: step.id},
            resume_params_ref: Keyword.get(opts, :resume_params_override, params)
          },
          ReadyEffectContext.attach(%{
            user_id: objective.user_id,
            objective_id: objective.id,
            step_id: step.id,
            parent_objective_id: objective.parent_objective_id,
            selected_action: step.candidate_action,
            selected_action_module: action_module
          })
        )

      send(Keyword.fetch!(opts, :test_pid), {:grounded_confirmation, confirmation["id"]})
      {:blocked, {:needs_confirmation, confirmation["id"]}, state}
    end

    def operation(operation, state, opts), do: DefaultAdapter.operation(operation, state, opts)
  end

  test "runs the full lifecycle in order and persists attempt, progress, and completion" do
    assert {:ok, child} =
             create_child(%{
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
             create_child(%{
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

  test "reviewed DirectAnswer completion atomically binds the exact answer and closed receipt" do
    answer = "A reviewed task-neutral child answer."
    {child, step, receipt, task_digest} = reviewed_completion_fixture(answer)

    assert {:ok, completed} =
             Lifecycle.run(child.id,
               adapter: QualityCompletionAdapter,
               quality_step: step,
               quality_answer: answer,
               quality_receipt: receipt
             )

    assert completed.status == "completed"
    assert completed.last_observation_summary == answer

    assert [completed_step] = Objectives.list_steps(child.id)
    assert completed_step.id == step.id
    assert completed_step.status == "completed"
    assert completed_step.result_summary == answer

    assert completed_event =
             Enum.find(Objectives.list_events(child.id), &(&1.kind == "run_completed"))

    payload = Jason.decode!(completed_event.payload)
    assert Map.keys(payload) |> Enum.sort() == ~w[quality_receipt step_id step_status]
    assert payload["step_id"] == step.id
    assert payload["step_status"] == "completed"

    binding = %{
      objective_id: child.id,
      step_id: step.id,
      task_contract_sha256: task_digest,
      final_answer: answer
    }

    assert {:ok, ^receipt, receipt_digest} =
             QualityReceipt.from_event_payload(payload, binding)

    assert {:ok, ^receipt_digest} = QualityReceipt.digest(receipt)
    refute Map.has_key?(payload, "summary")
  end

  test "a replay-valid catalog-v1 receipt cannot become a new completion event" do
    answer = "A replay-valid catalog-v1 reviewed answer."
    {child, step, current_receipt, _task_digest} = reviewed_completion_fixture(answer)

    assert {:ok, contract} = child |> Grounding.resolve() |> QualityPolicy.build()

    assert {:ok, %{"1" => legacy_digest}} =
             QualityPolicy.receipt_task_digests(contract)

    legacy_receipt =
      current_receipt
      |> Map.put("rule_catalog_version", 1)
      |> Map.put("task_contract_sha256", legacy_digest)

    assert {:error, {:invalid_fanout_worker_quality_receipt, :invalid_quality_receipt}} =
             Lifecycle.run(child.id,
               adapter: QualityCompletionAdapter,
               quality_step: step,
               quality_answer: answer,
               quality_receipt: legacy_receipt
             )

    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)
    refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_completed"))
  end

  test "current DirectAnswer completion rejects mutated review protocol and phase evidence" do
    answer = "A phase-reviewed task-neutral child answer."

    mutations = [
      &Map.put(&1, "review_protocol_version", 2),
      &Map.put(&1, "critic_group_count", 1),
      &Map.put(&1, "rule_group_catalog_version", 2),
      &Map.put(&1, "rule_group_catalog_sha256", String.duplicate("f", 64)),
      &Map.put(&1, "draft_call_count", 0),
      &Map.put(&1, "initial_critic_call_count", 1),
      &Map.put(&1, "provider_call_count", 4),
      &Map.put(&1, "accepted_assessment_sha256", String.duplicate("e", 64))
    ]

    Enum.each(mutations, fn mutate ->
      {child, step, receipt, _task_digest} = reviewed_completion_fixture(answer)

      assert {:error, {:invalid_fanout_worker_quality_receipt, :invalid_quality_receipt}} =
               Lifecycle.run(child.id,
                 adapter: QualityCompletionAdapter,
                 quality_step: step,
                 quality_answer: answer,
                 quality_receipt: mutate.(receipt)
               )

      assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)
      refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_completed"))
    end)
  end

  test "reviewed completion resumes idempotently when its step already completed" do
    answer = "A reviewed task-neutral child answer."
    {child, step, receipt, _task_digest} = reviewed_completion_fixture(answer)

    assert {:ok, completed_step} =
             Objectives.transition_step(
               step,
               "completed",
               %{result_summary: answer},
               ReadyEffectContext.context()
             )

    assert {:ok, completed} =
             Lifecycle.run(child.id,
               adapter: QualityCompletionAdapter,
               quality_step: completed_step,
               quality_answer: answer,
               quality_receipt: receipt
             )

    assert completed.status == "completed"
    assert completed.last_observation_summary == answer

    assert Enum.count(Objectives.list_events(child.id), &(&1.kind == "run_completed")) == 1

    assert [%{id: step_id, status: "completed", result_summary: ^answer}] =
             Objectives.list_steps(child.id)

    assert step_id == step.id
  end

  test "an incompatible terminal step rolls back reviewed Objective completion and event" do
    answer = "A reviewed task-neutral child answer."
    {child, step, receipt, _task_digest} = reviewed_completion_fixture(answer)

    assert {:ok, failed_step} =
             Objectives.transition_step(
               step,
               "failed",
               %{result_summary: "earlier failure"},
               ReadyEffectContext.context()
             )

    assert {:error, {:incompatible_terminal_step_status, step_id, "failed", "completed"}} =
             Lifecycle.run(child.id,
               adapter: QualityCompletionAdapter,
               quality_step: failed_step,
               quality_answer: answer,
               quality_receipt: receipt
             )

    assert step_id == step.id
    assert {:ok, still_running} = Objectives.get_objective(child.id)
    assert still_running.status == "running"
    refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_completed"))

    assert [%{id: step_id, status: "failed", result_summary: "earlier failure"}] =
             Objectives.list_steps(child.id)

    assert step_id == step.id
  end

  test "a non-final child cannot persist or finalize another child's transient Step" do
    assert {:ok, child} =
             create_child(%{
               user_id: "alice",
               title: "Bound child",
               objective: "Complete only the bound child",
               fanout_role: "child"
             })

    sibling =
      child.parent_objective_id
      |> Fanout.children()
      |> Enum.find(&(&1.id != child.id))

    assert {:ok, foreign_step} =
             Objectives.create_step(
               %{
                 objective_id: sibling.id,
                 kind: "action",
                 status: "selected",
                 stage: "propose_steps",
                 candidate_action: "list_objectives",
                 action_params: %{user_id: "alice"}
               },
               ReadyEffectContext.context()
             )

    assert {:error,
            {:terminal_step_objective_mismatch, step_id, step_objective_id, child_objective_id}} =
             Lifecycle.run(child.id,
               adapter: ForeignStepAdapter,
               foreign_step: foreign_step
             )

    assert step_id == foreign_step.id
    assert step_objective_id == sibling.id
    assert child_objective_id == child.id

    assert {:ok, still_running} = Objectives.get_objective(child.id)
    assert still_running.status == "running"
    assert still_running.current_step_id == nil
    refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_completed"))

    assert [%{id: step_id, status: "selected", result_summary: nil}] =
             Objectives.list_steps(sibling.id)

    assert step_id == foreign_step.id
  end

  test "a required reviewed DirectAnswer receipt cannot be omitted or rebound to another answer" do
    answer = "A reviewed task-neutral child answer."

    {missing_child, missing_step, _receipt, _task_digest} =
      reviewed_completion_fixture(answer)

    assert {:error, :missing_fanout_worker_quality_receipt} =
             Lifecycle.run(missing_child.id,
               adapter: QualityCompletionAdapter,
               quality_step: missing_step,
               quality_answer: answer
             )

    assert {:ok, %{status: "failed"}} = Objectives.get_objective(missing_child.id)
    refute Enum.any?(Objectives.list_events(missing_child.id), &(&1.kind == "run_completed"))

    {changed_child, changed_step, receipt, _task_digest} =
      reviewed_completion_fixture(answer)

    assert {:error, {:invalid_fanout_worker_quality_receipt, _reason}} =
             Lifecycle.run(changed_child.id,
               adapter: QualityCompletionAdapter,
               quality_step: changed_step,
               quality_answer: answer <> " changed",
               quality_receipt: receipt
             )

    assert {:ok, %{status: "failed"}} = Objectives.get_objective(changed_child.id)
    refute Enum.any?(Objectives.list_events(changed_child.id), &(&1.kind == "run_completed"))
  end

  test "steering received during proposal replans before execution" do
    assert {:ok, child} =
             create_child(%{
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
             create_child(%{
               user_id: "alice",
               title: "Original task",
               objective: "Explain OTP supervision as a restaurant",
               fanout_role: "child"
             })

    test_pid = self()

    task =
      Task.async(fn ->
        Lifecycle.run(child.id,
          adapter: DelayedExecutionAdapter,
          candidate_action: "list_objectives",
          test_pid: test_pid
        )
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

  test "a repeated identical steering event still clears the prior response and reruns safely" do
    directive = "Explain OTP supervision as a hospital"

    assert {:ok, child} =
             create_child(%{
               user_id: "alice",
               title: directive,
               objective: directive,
               fanout_role: "child"
             })

    assert {:ok, _first} = Steering.steer("alice", child.id, directive)
    assert {:ok, already_steered} = Steering.apply_pending(child.id)
    assert already_steered.objective == directive

    test_pid = self()

    task =
      Task.async(fn ->
        Lifecycle.run(child.id,
          adapter: DelayedExecutionAdapter,
          candidate_action: "list_objectives",
          test_pid: test_pid
        )
      end)

    assert_receive {:execution_in_flight, runner, ^directive}, 2_000
    assert {:ok, _second} = Steering.steer("alice", child.id, directive)
    send(runner, :finish_execution)

    assert_receive {:executed_objective, 1, ^directive}, 2_000
    assert_receive {:executed_objective, 2, ^directive}, 2_000
    assert {:ok, completed} = Task.await(task, 2_000)
    assert completed.last_observation_summary == "executed: #{directive}"

    assert Enum.count(Objectives.list_events(child.id), &(&1.kind == "steer_applied")) == 2
  end

  test "steering after a possibly effectful execution blocks instead of replaying it" do
    assert {:ok, child} =
             create_child(%{
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
             create_child(%{
               user_id: "alice",
               title: "Child",
               objective: "List objectives",
               fanout_role: "child"
             })

    assert {:ok, _step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "authorize_step",
                 candidate_action: "list_objectives",
                 action_params: %{user_id: "alice"}
               },
               ReadyEffectContext.context()
             )

    assert {:ok, completed} = Lifecycle.run(child.id)
    assert completed.status == "completed"
    assert completed.last_observation_summary =~ "objective(s)"
  end

  test "missing proposal is filled by an inert intent decision before execution" do
    assert {:ok, child} =
             create_child(%{
               user_id: "alice",
               title: "Child",
               objective: "Wait",
               fanout_role: "child"
             })

    assert {:ok, completed} = Lifecycle.run(child.id)
    assert completed.status == "completed"

    assert [%{candidate_action: "direct_answer", status: "completed"}] =
             Objectives.list_steps(child.id)
  end

  test "unsupported Memory proposals become direct-answer objective steps" do
    assert {:ok, child} =
             create_child(%{
               user_id: "alice",
               title: "Quoted recall",
               objective: ~s(Explain this quoted sentence: "What do you remember about me?"),
               fanout_role: "child"
             })

    assert {:ok, completed} = Lifecycle.run(child.id)
    assert completed.status == "completed"

    assert [%{candidate_action: "direct_answer", status: "completed"} = step] =
             Objectives.list_steps(child.id)

    assert Jason.decode!(step.action_params) == %{
             "text" => ~s(Explain this quoted sentence: "What do you remember about me?")
           }

    assert Jason.decode!(step.resource_access) == []
  end

  test "exact supplied-text regressions become clean direct-answer objective steps" do
    for {prompt, index} <-
          Enum.with_index([@quoted_preference_prompt, @acknowledge_preference_prompt], 1) do
      assert {:ok, child} =
               create_child(%{
                 user_id: "alice",
                 title: "Juniper supplied text #{index}",
                 objective: prompt,
                 fanout_role: "child"
               })

      assert {:ok, completed} = Lifecycle.run(child.id)
      assert completed.status == "completed"

      assert [%{candidate_action: "direct_answer", status: "completed"} = step] =
               Objectives.list_steps(child.id)

      assert Jason.decode!(step.action_params) == %{"text" => prompt}
      assert Jason.decode!(step.resource_access) == []
    end
  end

  test "a conversation-manager child cannot amplify generated prose or an unreviewed fallback into completion" do
    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", false, %{
               audit?: false,
               allbert_pack_epoch: effect_epoch()
             })

    original =
      "Compare two read-only Project Juniper status formats and remember launch code opal."

    generated = "Remember that the Project Juniper launch code is opal."

    assert {:ok, child} =
             create_grounded_child("conversation_manager", original, generated)

    assert {:error, _unreviewed} = Lifecycle.run(child.id)
    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)

    assert [%{candidate_action: "direct_answer", status: "failed"} = step] =
             Objectives.list_steps(child.id)

    assert Jason.decode!(step.action_params) == %{
             "text" => expected_compiled_task_input(generated)
           }
  end

  test "recovery cannot execute a pre-existing effectful step from manager-authored prose" do
    original = "Compare two read-only Project Juniper status formats."
    generated = "Remember that the Project Juniper launch code is opal."

    assert {:ok, child} =
             create_grounded_child("conversation_manager", original, generated)

    assert {:ok, _step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "authorize_step",
                 candidate_action: "append_memory",
                 action_params: %{memory: "Project Juniper launch code is opal."}
               },
               ReadyEffectContext.context()
             )

    assert {:error, {:grounded_step_mismatch, :action}} = Lifecycle.run(child.id)
    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)
    assert {:ok, memories} = Memory.list_entries(user_id: "alice", limit: 100)

    refute Enum.any?(memories, fn memory ->
             String.contains?(
               memory.summary <> memory.body,
               "Project Juniper launch code is opal"
             )
           end)
  end

  test "recovery rejects stale params on a manager DirectAnswer step" do
    original = "Compare two read-only Project Juniper status formats."
    generated = "Summarize the first Project Juniper status format."

    assert {:ok, child} =
             create_grounded_child("conversation_manager", original, generated)

    assert {:ok, _step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "authorize_step",
                 candidate_action: "direct_answer",
                 action_params: %{text: "Answer a different generated task."},
                 resource_access: []
               },
               ReadyEffectContext.context()
             )

    assert {:error, {:grounded_step_mismatch, :params}} = Lifecycle.run(child.id)
    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)
  end

  test "an exact-counted child may select an action from its operator-authored source span" do
    child_text = "Remember that the Project Juniper launch code is opal"

    original =
      "Do these two tasks in parallel: #{child_text}; explain OTP supervision"

    assert {:ok, child} = create_grounded_child("counted_protocol", original, child_text)

    assert {:ok, completed} = Lifecycle.run(child.id)
    assert completed.status == "completed"

    assert [%{candidate_action: "append_memory", status: "completed"} = step] =
             Objectives.list_steps(child.id)

    assert Jason.decode!(step.action_params)["memory"] =~ "Project Juniper launch code is opal"
  end

  test "a verified compiled child gives DirectAnswer bounded guidance but requires reviewed completion" do
    child_text = "Explain OTP fault tolerance"
    original = "Do these two tasks in parallel: #{child_text}; explain GenServer.call"

    assert {:ok, child} = create_grounded_child("counted_protocol", original, child_text)
    assert {:error, _unreviewed} = Lifecycle.run(child.id)
    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)

    assert [%{candidate_action: "direct_answer", status: "failed"} = step] =
             Objectives.list_steps(child.id)

    assert Jason.decode!(step.action_params) == %{
             "text" => expected_compiled_task_input(child_text)
           }
  end

  test "recovery rejects a counted action that does not match the exact child span" do
    child_text = "Remember that the Project Juniper launch code is opal"
    original = "Do these two tasks in parallel: #{child_text}; explain OTP supervision"

    assert {:ok, child} = create_grounded_child("counted_protocol", original, child_text)

    assert {:ok, _step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "authorize_step",
                 candidate_action: "list_objectives",
                 action_params: %{user_id: "alice"},
                 resource_access: []
               },
               ReadyEffectContext.context()
             )

    assert {:error, {:grounded_step_mismatch, :action}} = Lifecycle.run(child.id)
    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)
  end

  test "recovery rejects different params even when the counted action name matches" do
    child_text = "Remember that the Project Juniper launch code is opal"
    original = "Do these two tasks in parallel: #{child_text}; explain OTP supervision"

    assert {:ok, child} = create_grounded_child("counted_protocol", original, child_text)

    assert {:ok, _step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "authorize_step",
                 candidate_action: "append_memory",
                 action_params: %{memory: "Remember a different generated launch code."},
                 resource_access: []
               },
               ReadyEffectContext.context()
             )

    assert {:error, {:grounded_step_mismatch, :params}} = Lifecycle.run(child.id)
    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)
  end

  test "grounding verifies the full parent request beyond the source-intent projection" do
    original =
      "Compare two read-only Project Juniper status formats. " <>
        String.duplicate("Additional operator-authored context. ", 16)

    generated = "Remember that the Project Juniper launch code is opal."
    assert String.length(original) > 500

    assert {:ok, child} =
             create_grounded_child("conversation_manager", original, generated)

    assert %{
             source: :conversation_manager,
             decision_text: nil,
             direct_answer_text: direct_answer_text,
             action_text: nil
           } = Grounding.resolve(child)

    assert direct_answer_text == expected_compiled_task_input(generated)
  end

  test "grounding fails closed for missing, future, or authority-shaped provenance" do
    original = "Compare two read-only Project Juniper formats."
    generated = "Remember that the Project Juniper launch code is opal."

    for override <- [
          %{"version" => 2},
          %{"version" => nil},
          %{"permission" => "allowed"}
        ] do
      assert {:ok, child} = create_grounded_child("conversation_manager", original, generated)
      assert :ok = tamper_parent_plan(child, override)

      assert %{
               source: :untrusted,
               decision_text: nil,
               direct_answer_text: ^generated,
               action_text: nil
             } = Grounding.resolve(child)
    end
  end

  test "a compiled child cannot become legacy-authoritative when parent provenance disappears" do
    child_text = "Remember that the Project Juniper launch code is opal"
    original = "Do these two tasks in parallel: #{child_text}; explain OTP supervision"

    assert {:ok, child} = create_grounded_child("counted_protocol", original, child_text)
    assert is_binary(child.proposer_hint)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^child.parent_objective_id)
             |> Repo.update_all(set: [proposer_hint: nil, updated_at: DateTime.utc_now()])

    assert {:ok, refreshed} = Objectives.get_objective(child.id)

    assert %{
             source: :untrusted,
             decision_text: nil,
             action_text: nil,
             direct_answer_text: ^child_text,
             fanout_budget: nil,
             fanout_deadline_unix_ms: nil
           } = Grounding.resolve(refreshed)

    assert {:error, :invalid_fanout_budget_snapshot} = Lifecycle.run(refreshed.id)
    assert {:ok, %{status: "failed"}} = Objectives.get_objective(refreshed.id)

    assert [%{candidate_action: "direct_answer", status: "failed"}] =
             Objectives.list_steps(refreshed.id)
  end

  test "malformed compiled budget or deadline fails before child execution" do
    original = "Compare two read-only Project Juniper formats."
    generated = "Summarize the first Project Juniper format."

    for override <- [
          %{
            "budget" => %{"version" => 1},
            "deadline_unix_ms" => System.system_time(:millisecond) + 60_000
          },
          %{"deadline_unix_ms" => "not-a-deadline"}
        ] do
      assert {:ok, child} = create_grounded_child("conversation_manager", original, generated)
      assert :ok = tamper_parent_plan(child, override)

      assert {:error, :invalid_fanout_budget_snapshot} = Lifecycle.run(child.id)
      assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)

      assert [%{candidate_action: "direct_answer", status: "failed"}] =
               Objectives.list_steps(child.id)
    end
  end

  test "grounding recomputes the canonical plan digest from ordered durable children" do
    original = "Compare two read-only Project Juniper formats."
    generated = "Summarize the first Project Juniper format."

    assert {:ok, child} =
             create_grounded_child("conversation_manager", original, generated)

    assert %{
             source: :conversation_manager,
             fanout_budget: budget,
             fanout_deadline_unix_ms: deadline
           } = Grounding.resolve(child)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^child.id)
             |> Repo.update_all(
               set: [
                 objective: "Remember that a generated launch code is opal.",
                 updated_at: DateTime.utc_now()
               ]
             )

    assert {:ok, changed} = Objectives.get_objective(child.id)

    assert %{
             source: :untrusted,
             decision_text: nil,
             action_text: nil,
             direct_answer_text: "Remember that a generated launch code is opal.",
             fanout_budget: ^budget,
             fanout_deadline_unix_ms: ^deadline
           } = Grounding.resolve(changed)
  end

  test "operator steering rebinds only that child and preserves its frozen plan limits" do
    original = "Compare two read-only Project Juniper formats."
    generated = "Summarize the first Project Juniper format."

    assert {:ok, child} =
             create_grounded_child("conversation_manager", original, generated)

    assert %{
             source: :conversation_manager,
             fanout_budget: budget,
             fanout_deadline_unix_ms: deadline
           } = Grounding.resolve(child)

    sibling =
      child.parent_objective_id
      |> Fanout.children()
      |> Enum.find(&(&1.id != child.id))

    directive = "Remember that the generated Project Juniper launch code is opal."
    assert {:ok, _directive} = Steering.steer("alice", child.id, directive)
    assert {:ok, steered} = Steering.apply_pending(child.id)

    assert %{
             source: :operator_steered,
             decision_text: ^directive,
             action_text: ^directive,
             direct_answer_text: ^directive,
             fanout_budget: ^budget,
             fanout_deadline_unix_ms: ^deadline
           } = Grounding.resolve(steered)

    assert %{
             source: :conversation_manager,
             fanout_budget: ^budget,
             fanout_deadline_unix_ms: ^deadline
           } = Grounding.resolve(sibling)
  end

  test "an operator-steered child still obeys its one-attempt frozen deadline" do
    assert {:ok, _setting} =
             AllbertAssist.Settings.put(
               "objectives.fanout.max_worker_attempts_per_child",
               1,
               %{audit?: false, allbert_pack_epoch: effect_epoch()}
             )

    original = "Compare two read-only Project Juniper formats."
    generated = "Summarize the first Project Juniper format."

    assert {:ok, child} =
             create_grounded_child("conversation_manager", original, generated, %{
               "deadline_unix_ms" => System.system_time(:millisecond) - 1
             })

    directive = "Remember that the generated Project Juniper launch code is amber."
    assert {:ok, _directive} = Steering.steer("alice", child.id, directive)
    assert {:ok, steered} = Steering.apply_pending(child.id)

    assert %{
             source: :operator_steered,
             fanout_budget: %{"worker_attempts_per_child" => 1},
             fanout_deadline_unix_ms: deadline
           } = Grounding.resolve(steered)

    assert deadline < System.system_time(:millisecond)
    assert {:error, :fanout_plan_deadline_exhausted} = Lifecycle.run(steered.id)

    assert {:ok, %{status: "failed", run_attempt_count: 1}} =
             Objectives.get_objective(steered.id)
  end

  test "an approved grounded confirmation executes its bound action-normalized params" do
    normalized_params = %{"user_id" => "alice", "limit" => 5}

    {child, confirmation_id} =
      park_grounded_counted_confirmation(resume_params_override: normalized_params)

    assert [parked] = Objectives.list_steps(child.id)
    refute Map.has_key?(Jason.decode!(parked.action_params), "limit")
    assert {:ok, expected_digest} = ResumeParamsBinding.digest(normalized_params)
    assert parked.confirmation_resume_params_sha256 == expected_digest

    assert {:ok, %{"status" => "approved"}} =
             Confirmations.resolve(
               confirmation_id,
               :approved,
               %{actor: "alice", decision_source: "operator"},
               ReadyEffectContext.context()
             )

    assert {:ok, completed} =
             Lifecycle.run(child.id,
               adapter: GroundedConfirmationAdapter,
               test_pid: self(),
               allbert_pack_epoch: ReadyEffectContext.context().allbert_pack_epoch
             )

    assert completed.status == "completed"

    assert [%{candidate_action: "list_objectives", status: "completed"}] =
             Objectives.list_steps(child.id)
  end

  test "a changed confirmation resume packet is denied at approval lookup and before Runner" do
    {child, confirmation_id} =
      park_grounded_counted_confirmation(resume_params_override: %{"user_id" => "alice"})

    assert {:ok, pending} = Confirmations.read(confirmation_id)

    tampered = put_in(pending, ["resume_params_ref", "user_id"], "mallory")

    File.write!(
      ConfirmationPersistence.pending_path(confirmation_id),
      YamlCodec.encode!(tampered)
    )

    assert {:error, :confirmation_resume_params_mismatch} =
             Objectives.fanout_confirmation_target(tampered)

    assert {:ok, %{child: %{id: child_id}}} =
             Objectives.fanout_confirmation_target(tampered,
               verify_resume_binding?: false
             )

    assert child_id == child.id

    assert {:ok, %{"status" => "approved"}} =
             Confirmations.resolve(
               confirmation_id,
               :approved,
               %{actor: "alice", decision_source: "operator"},
               ReadyEffectContext.context()
             )

    assert {:error, :confirmation_resume_params_mismatch} =
             Lifecycle.run(child.id,
               adapter: GroundedConfirmationAdapter,
               test_pid: self()
             )

    assert {:ok, %{status: "failed"}} = Objectives.get_objective(child.id)
  end

  test "each operation receives its own resolved-settings pin" do
    counter = :counters.new(1, [])
    Process.put(@resolution_hook_key, fn -> :counters.add(counter, 1, 1) end)

    assert {:ok, child} =
             create_child(%{
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
               audit?: false,
               allbert_pack_epoch: effect_epoch()
             })

    assert {:ok, child} =
             create_child(%{
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
             create_child(%{
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

  test "a blocked or terminal objective cannot begin another run attempt" do
    for status <- ~w[blocked completed cancelled failed abandoned] do
      assert {:ok, child} =
               create_child(%{
                 user_id: "alice",
                 title: "Non-runnable #{status}",
                 objective: "Stay #{status}",
                 fanout_role: "child",
                 status: status,
                 run_attempt_count: 1
               })

      assert {:error, {:objective_not_runnable, ^status}} = Lifecycle.run(child.id)
      assert {:ok, unchanged} = Objectives.get_objective(child.id)
      assert unchanged.status == status
      assert unchanged.run_attempt_count == 1
      refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_started"))
    end
  end

  test "Budget v1 DirectAnswer recovery fails once and cannot resume through steering" do
    legacy_budget = %{
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

    assert {:ok, ^legacy_budget} = Budget.validate_snapshot(legacy_budget)

    assert {:ok, child} =
             create_grounded_child(
               "conversation_manager",
               "Prepare two historical recovery analyses.",
               "Analyze the first historical recovery fixture.",
               %{"budget" => legacy_budget}
             )

    assert {:ok, {:failed, failed}} = Lifecycle.reconcile_quality_protocol_upgrade(child)
    assert failed.status == "failed"
    assert failed.review_reason == "quality_protocol_upgrade_required"
    assert failed.run_attempt_count == 0
    assert %DateTime{} = failed.completed_at

    assert {:ok, {:failed, same}} = Lifecycle.reconcile_quality_protocol_upgrade(failed)
    assert same.id == child.id

    assert {:error, :terminal} =
             Steering.steer(
               "alice",
               child.id,
               "Analyze a replacement historical recovery fixture."
             )

    assert {:error, {:objective_not_runnable, "failed"}} =
             Lifecycle.run(child.id, adapter: RecordingAdapter, test_pid: self())

    assert {:ok, unchanged} = Objectives.get_objective(child.id)
    assert unchanged.status == "failed"
    assert unchanged.review_reason == "quality_protocol_upgrade_required"
    assert unchanged.run_attempt_count == 0

    assert Enum.count(Objectives.list_events(child.id), &(&1.kind == "run_failed")) == 1
    refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_started"))
    refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "steer_applied"))
    refute_receive {:operation, _operation}, 100
  end

  test "same-digest E2 rolls back the lifecycle terminal transition after its child write" do
    legacy_budget = %{
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

    assert {:ok, child} =
             create_grounded_child(
               "conversation_manager",
               "Prepare two historical rollback analyses.",
               "Analyze the first historical rollback fixture.",
               %{"budget" => legacy_budget}
             )

    original = Process.whereis(AllbertAssist.Pack.Readiness)
    true = Process.unregister(AllbertAssist.Pack.Readiness)

    {:ok, replacement} =
      SameDigestReadiness.start_link(name: AllbertAssist.Pack.Readiness)

    on_exit(fn ->
      if Process.whereis(AllbertAssist.Pack.Readiness) == replacement,
        do: Process.unregister(AllbertAssist.Pack.Readiness)

      if Process.alive?(replacement), do: GenServer.stop(replacement)

      if Process.alive?(original) and is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
        do: Process.register(original, AllbertAssist.Pack.Readiness)
    end)

    assert {:ok, e1} = EffectGuard.admit_ready()

    assert {:error, :stale_epoch} =
             RealLifecycle.reconcile_quality_protocol_upgrade(
               child,
               allbert_pack_epoch: e1,
               force_quality_protocol_upgrade?: true,
               transaction_hook: fn _child ->
                 :ok =
                   SameDigestReadiness.replace(replacement)
               end
             )

    assert {:ok, unchanged} = Objectives.get_objective(child.id)
    assert unchanged.status == "open"
    assert unchanged.review_reason == nil
    refute Enum.any?(Objectives.list_events(child.id), &(&1.kind == "run_failed"))
  end

  test "same-digest E2 prevents steering from resolving a parked confirmation" do
    {child, confirmation_id} = park_grounded_counted_confirmation([])
    assert {:ok, %{"status" => "pending"}} = Confirmations.read(confirmation_id)

    original = Process.whereis(AllbertAssist.Pack.Readiness)
    true = Process.unregister(AllbertAssist.Pack.Readiness)

    {:ok, replacement} =
      SameDigestReadiness.start_link(
        name: AllbertAssist.Pack.Readiness,
        replace_after_status_calls: 5
      )

    on_exit(fn ->
      if Process.whereis(AllbertAssist.Pack.Readiness) == replacement,
        do: Process.unregister(AllbertAssist.Pack.Readiness)

      if Process.alive?(replacement), do: GenServer.stop(replacement)

      if Process.alive?(original) and is_nil(Process.whereis(AllbertAssist.Pack.Readiness)),
        do: Process.register(original, AllbertAssist.Pack.Readiness)
    end)

    assert {:ok, e1} = EffectGuard.admit_ready()

    assert {:error, :stale_epoch} =
             RealSteering.steer(
               "alice",
               child.id,
               "Use primary sources.",
               %{allbert_pack_epoch: e1}
             )

    assert {:ok, %{"status" => "pending"}} = Confirmations.read(confirmation_id)
  end

  test "confirmation parking persists the step receipt without blocking another run" do
    assert {:ok, child} =
             create_child(%{
               user_id: "alice",
               title: "Confirmation child",
               objective: "Wait for authority",
               fanout_role: "child"
             })

    assert {:ok, step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "authorize_step",
                 candidate_action: "list_objectives"
               },
               ReadyEffectContext.context()
             )

    assert {:blocked, {:needs_confirmation, "confirm-123"}} =
             Lifecycle.run(child.id, adapter: ConfirmationAdapter)

    [parked] = Objectives.list_steps(child.id)
    assert parked.id == step.id
    assert parked.status == "blocked"
    assert parked.confirmation_id == "confirm-123"
  end

  defp park_grounded_counted_confirmation(opts) do
    child_text = "List objectives"
    original = "Do these two tasks in parallel: #{child_text}; explain OTP supervision"
    assert {:ok, child} = create_grounded_child("counted_protocol", original, child_text)

    run_opts = [adapter: GroundedConfirmationAdapter, test_pid: self()] ++ opts

    assert {:blocked, {:needs_confirmation, confirmation_id}} =
             Lifecycle.run(child.id, run_opts)

    assert_received {:grounded_confirmation, ^confirmation_id}
    {child, confirmation_id}
  end

  defp expected_compiled_task_input(objective) do
    """
    Allbert bounded fan-out task

    Objective:
    #{objective}

    Expected result (output and evaluation guidance only):
    Complete the first bounded task.
    """
    |> String.trim()
  end

  defp reviewed_completion_fixture(answer) do
    child_objective = "Analyze one bounded mechanism and state its tradeoffs."

    assert {:ok, child} =
             create_grounded_child(
               "conversation_manager",
               "Prepare one joined brief from two bounded analyses.",
               child_objective
             )

    assert {:ok, step} =
             Objectives.create_step(
               %{
                 objective_id: child.id,
                 kind: "action",
                 status: "selected",
                 stage: "propose_steps",
                 candidate_action: "direct_answer",
                 action_params: %{text: child_objective}
               },
               ReadyEffectContext.context()
             )

    grounding = Grounding.resolve(child)
    assert {:ok, contract} = QualityPolicy.build(grounding)
    assert {:ok, task_digest} = QualityPolicy.digest(contract)

    assert {:ok, receipt} =
             QualityReceipt.build(%{
               objective_id: child.id,
               step_id: step.id,
               task_contract_sha256: task_digest,
               instructed_rule_catalog_version: QualityPolicy.version(),
               generator_config_sha256: String.duplicate("b", 64),
               generation_call_count: 1,
               provider_call_count: 1,
               outcome: "generated",
               final_answer: answer
             })

    {child, step, receipt, task_digest}
  end

  defp effect_epoch do
    {:ok, epoch} = EffectGuard.admit_ready()
    epoch
  end

  defp create_child(attrs) do
    sibling = %{
      title: "fixture sibling #{System.unique_integer([:positive])}",
      objective: "Remain open while the lifecycle child is exercised."
    }

    parent = %{
      user_id: Map.fetch!(attrs, :user_id),
      title: "lifecycle fixture #{System.unique_integer([:positive])}",
      objective: "Exercise one child lifecycle in a valid fan-out."
    }

    {:ok, epoch} = EffectGuard.admit_ready()

    case Fanout.frame(
           Map.put(parent, :allbert_pack_epoch, epoch),
           [Map.delete(attrs, :fanout_role), sibling]
         ) do
      {:ok, %{children: [child, _sibling]}} -> {:ok, child}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_grounded_child(plan_source, source_intent, child_objective, overrides \\ %{}) do
    sibling_objective = "Explain OTP supervision"

    plan_children = [
      %{
        title: child_objective,
        objective: child_objective,
        expected_result: "Complete the first bounded task."
      },
      %{
        title: sibling_objective,
        objective: sibling_objective,
        expected_result: "Complete the second bounded task."
      }
    ]

    source = if plan_source == "counted_protocol", do: :exact_counted, else: :model
    assert {:ok, compiled} = FanoutPlan.compile(source_intent, plan_children, source: source)
    manager_attempts = if source == :model, do: 1, else: 0
    assert {:ok, budget} = Budget.resolve(2, manager_attempts)

    plan =
      compiled
      |> FanoutPlan.provenance()
      |> Map.put("manager_attempts", manager_attempts)
      |> Map.put("budget", budget)
      |> Map.put("deadline_unix_ms", System.system_time(:millisecond) + 60_000)
      |> Map.merge(overrides)

    parent = %{
      user_id: "alice",
      title: "Grounded fanout fixture",
      objective: source_intent,
      proposer_hint: %{"fanout_plan" => plan}
    }

    {:ok, epoch} = EffectGuard.admit_ready()

    case Fanout.frame(
           Map.put(parent, :allbert_pack_epoch, epoch),
           FanoutPlan.child_attrs(compiled)
         ) do
      {:ok, %{children: [child, _sibling]}} -> {:ok, child}
      {:error, reason} -> {:error, reason}
    end
  end

  defp tamper_parent_plan(child, overrides) do
    assert {:ok, parent} = Objectives.get_objective(child.parent_objective_id)
    assert %{"fanout_plan" => plan} = Jason.decode!(parent.proposer_hint)

    tampered_hint = Jason.encode!(%{"fanout_plan" => Map.merge(plan, overrides)})

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [proposer_hint: tampered_hint, updated_at: DateTime.utc_now()]
             )

    :ok
  end
end
