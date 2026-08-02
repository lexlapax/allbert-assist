defmodule AllbertAssist.Objectives.Runs.WorkerJidoAdapterTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.Fanout.{Budget, ReviewRound}
  alias AllbertAssist.Objectives.ObservationSummary
  alias AllbertAssist.Objectives.Runs.{CancelToken, Worker}
  alias AllbertAssist.Objectives.Runs.Worker.Commands.Execute
  alias AllbertAssist.Objectives.Runs.Worker.JidoAdapter
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

  defmodule DraftAnswerer do
    def answer(text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:draft_provider_call, text, context.fanout_worker_policy})
      {:ok, %{message: "Initial model draft.", diagnostic: %{status: :used}}}
    end
  end

  defmodule OrdinaryAnswerer do
    def answer(_text, context) do
      send(context.test_pid, {:ordinary_provider_call, Map.get(context, :fanout_worker_policy)})
      {:ok, %{message: "Ordinary one-call answer.", diagnostic: %{status: :used}}}
    end
  end

  defmodule LongRedactableAnswerer do
    @message "AIzaSyDUMMYSecretShapeForAudit59 " <> String.duplicate("durable answer ", 220)

    def message, do: @message

    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :long_redactable_draft_generated)
      {:ok, %{message: @message, diagnostic: %{status: :used}}}
    end
  end

  defmodule BlankDraftAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :blank_draft_generated)
      {:ok, %{message: " \n\t ", diagnostic: %{status: :used}}}
    end
  end

  defmodule PhaseAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      phase = Map.fetch!(context, :fanout_worker_phase)
      send(context.test_pid, {:worker_generation_call, phase})

      default =
        case phase do
          :draft -> "Initial phase-separated draft."
          :revision -> "Revised phase-separated answer."
        end

      message = get_in(context, [:worker_phase_messages, phase]) || default

      {:ok, %{message: message, diagnostic: %{status: :used}}}
    end
  end

  defmodule BlockingDraftAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :blocking_draft_started)
      Process.sleep(1_000)
      send(context.test_pid, :blocking_draft_returned)
      {:ok, %{message: "Late draft must not be accepted.", diagnostic: %{status: :used}}}
    end
  end

  defmodule TimeoutRecordingAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)

      send(
        context.test_pid,
        {:quality_deadline_context, context.model_timeout_ms,
         context.fanout_worker_deadline_monotonic_ms, context.fanout_review_deadline_monotonic_ms}
      )

      {:ok, %{message: "Deadline-bound draft.", diagnostic: %{status: :used}}}
    end
  end

  defmodule PhaseCritic do
    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      phase = Map.fetch!(context, :fanout_review_phase)
      group_id = request["group"]["id"]
      send(context.test_pid, {:worker_critic_call, phase, group_id})

      if Map.get(context, :record_critic_candidates, false) do
        send(
          context.test_pid,
          {:worker_critic_candidate, phase, group_id,
           get_in(request, ["sources", "candidate", "content"])}
        )
      end

      status =
        context
        |> Map.fetch!(:critic_statuses)
        |> Map.fetch!(phase)
        |> Map.get(group_id, "satisfied")

      assessments =
        Enum.map(request["group"]["rule_ids"], fn rule_id ->
          %{
            "rule_id" => rule_id,
            "status" => status,
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{"group_id" => group_id, "assessments" => assessments},
         reviewer_config_sha256: sha256("#{phase}:#{group_id}")
       }}
    end

    defp sha256(value) do
      :sha256
      |> :crypto.hash(value)
      |> Base.encode16(case: :lower)
    end
  end

  defmodule FailingDraftAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :draft_provider_failed)
      {:error, :provider_unavailable}
    end
  end

  defmodule RaisingDraftAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :raising_draft_provider_called)
      raise "injected provider exception after dispatch"
    end
  end

  defmodule ExitingDraftAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, :exiting_draft_provider_called)
      exit(:injected_provider_exit_after_dispatch)
    end
  end

  defmodule PreflightFailingDraftAnswerer do
    def answer(_text, context) do
      send(context.test_pid, :draft_preflight_failed)
      {:error, :model_spec_unavailable}
    end
  end

  defmodule DoubleAttemptAnswerer do
    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:double_provider_attempt, context.fanout_worker_phase})
      {:ok, %{message: "Over-budget answer.", diagnostic: %{status: :used}}}
    end
  end

  defmodule DoubleRevisionAttemptAnswerer do
    def answer(_text, context) do
      phase = context.fanout_worker_phase
      :ok = ProviderAttempt.mark(context)
      if phase == :revision, do: :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:phase_provider_attempt, phase})
      {:ok, %{message: "#{phase} answer.", diagnostic: %{status: :used}}}
    end
  end

  defmodule CancellingDraftAnswerer do
    alias AllbertAssist.Objectives.Runs.CancelToken

    def answer(_text, context) do
      :ok = ProviderAttempt.mark(context)
      :ok = CancelToken.cancel(context.cancel_token)
      send(context.test_pid, :draft_cancelled_before_review)

      {:ok,
       %{message: "Draft completed while cancellation arrived.", diagnostic: %{status: :used}}}
    end
  end

  defmodule UnavailableCritic do
    def assess(request, context) do
      send(context.test_pid, {:critic_unavailable, request["group"]["id"]})
      {:error, :fanout_review_profile_unavailable}
    end
  end

  defmodule DoubleAttemptCritic do
    alias AllbertAssist.Objectives.Fanout.ReviewRound
    alias AllbertAssist.Objectives.Runs.WorkerJidoAdapterTest.PhaseCritic

    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      PhaseCritic.assess(request, context)
    end
  end

  defmodule CancellingCritic do
    alias AllbertAssist.Objectives.Runs.CancelToken

    def assess(request, context) do
      :ok = CancelToken.cancel(context.cancel_token)
      send(context.test_pid, {:critic_cancelled_run, request["group"]["id"]})
      {:error, :review_cancelled}
    end
  end

  setup do
    previous = Application.get_env(:allbert_assist, DirectAnswer)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, DirectAnswer, previous),
        else: Application.delete_env(:allbert_assist, DirectAnswer)

      AllbertAssist.Settings.put("intent.direct_answer_model_enabled", false, %{audit?: false})
    end)

    :ok
  end

  test "execute consumes the closed DirectAnswer worker marker into one private draft" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    assert {:ok, contract} =
             QualityPolicy.build(%{
               source: :conversation_manager,
               original_request: "Prepare two independent analyses.",
               child_objective: "Analyze the first mechanism.",
               expected_result: "Cover its behavior and tradeoffs.",
               steering: nil
             })

    assert {:ok, task_digest} = QualityPolicy.digest(contract)
    assert {:ok, draft_prompt} = QualityPolicy.draft_prompt(contract)

    state = %{
      status: :ready,
      objective_id: "objective-draft",
      step_id: "step-draft",
      provider_call_count: 0,
      task_contract: contract,
      task_contract_sha256: task_digest,
      last_command: nil,
      last_result: nil
    }

    runner_context = %{
      user_id: "quality-worker-user",
      operator_id: "quality-worker-user",
      actor: "quality-worker-user",
      channel: "test",
      surface: "test",
      test_pid: self(),
      fanout_worker_policy: %{
        version: 1,
        provider_failover: :disabled,
        conversation_fanout: :disabled
      }
    }

    assert {:ok, draft} =
             Execute.run(
               %{
                 action_module: DirectAnswer,
                 action_params: %{text: draft_prompt},
                 runner_context: runner_context
               },
               %{state: state}
             )

    expected_worker_policy = runner_context.fanout_worker_policy
    assert_receive {:draft_provider_call, ^draft_prompt, ^expected_worker_policy}
    assert draft.status == :draft
    assert draft.provider_call_count == 1
    assert draft.draft_response.message == "Initial model draft."
    refute Map.has_key?(draft.draft_response, :fanout_worker)
    assert draft.last_command == :execute
    assert draft.last_result == {:ok, :draft}
  end

  test "a model-disabled quality child fails before any provider or reviewer call with count zero" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", false, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 0, reason: :quality_model_draft_unavailable}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context
             )

    refute_receive {:draft_provider_call, _prompt, _policy}
    refute_receive {:worker_critic_call, _phase, _group}
  end

  test "a failed draft provider cannot trigger action fallback or reviewer work and reports count one" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: FailingDraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 1, reason: :quality_model_draft_unavailable}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context
             )

    assert_receive :draft_provider_failed
    refute_receive {:worker_critic_call, _phase, _group}
  end

  test "a draft provider exception after dispatch remains one unresolved physical attempt" do
    assert_post_dispatch_draft_failure(
      RaisingDraftAnswerer,
      :raising_draft_provider_called
    )
  end

  test "a draft provider exit after dispatch remains one unresolved physical attempt" do
    assert_post_dispatch_draft_failure(
      ExitingDraftAnswerer,
      :exiting_draft_provider_called
    )
  end

  test "a draft preflight failure reports zero physical provider attempts" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PreflightFailingDraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 0, reason: :quality_model_draft_unavailable}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context
             )

    assert_receive :draft_preflight_failed
    refute_receive {:worker_critic_call, _phase, _group}
  end

  test "critics and receipt bind the exact redacted bounded durable draft bytes" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: LongRedactableAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    context =
      context
      |> Map.put(:record_critic_candidates, true)
      |> Map.put(:critic_statuses, %{initial: %{}})

    expected = ObservationSummary.normalize(LongRedactableAnswerer.message())
    assert String.length(expected) == 2_000
    refute expected == LongRedactableAnswerer.message()
    refute expected =~ "AIzaSyDUMMYSecretShapeForAudit59"
    assert expected =~ "[REDACTED]"

    assert {:ok, %{response: %{message: ^expected}, quality_receipt: receipt}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: PhaseCritic
             )

    assert receipt["provider_call_count"] == 3
    assert receipt["final_answer_sha256"] == sha256(expected)
    assert_receive :long_redactable_draft_generated

    assert_receive {:worker_critic_candidate, :initial, "coverage_fidelity", ^expected}
    assert_receive {:worker_critic_candidate, :initial, "safety_consistency", ^expected}
  end

  test "an empty normalized draft stops after its one generation attempt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: BlankDraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 1, reason: :quality_model_draft_unavailable}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: PhaseCritic
             )

    assert_receive :blank_draft_generated
    refute_receive {:worker_critic_call, _phase, _group}
  end

  test "multiple draft provider attempts fail closed with the exact count" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DoubleAttemptAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 2, reason: :quality_provider_attempt_bound_exceeded}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context)

    assert_receive {:double_provider_attempt, :draft}
  end

  test "multiple revision provider attempts fail closed before final critics" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DoubleRevisionAttemptAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    context =
      Map.put(context, :critic_statuses, %{
        initial: %{"coverage_fidelity" => "violated"},
        final: %{}
      })

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 5, reason: :quality_provider_attempt_bound_exceeded}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: PhaseCritic
             )

    assert_receive {:phase_provider_attempt, :draft}
    assert_receive {:phase_provider_attempt, :revision}
    refute_receive {:worker_critic_call, :final, _group}
  end

  test "quality work uses the remaining plan window instead of the legacy thirty-second cap" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: TimeoutRecordingAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {_grounding, context} = quality_worker_context()
    context = Map.put(context, :critic_statuses, %{initial: %{}})

    assert {:ok, %{quality_receipt: %{"provider_call_count" => 3}}} =
             Worker.run("direct_answer", %{text: "legacy compiled task input"}, context,
               quality_critic: PhaseCritic
             )

    assert_receive {:quality_deadline_context, timeout_ms, worker_deadline, review_deadline}
    assert timeout_ms > 30_000
    assert timeout_ms <= 60_000
    assert worker_deadline == review_deadline
  end

  test "an expired durable plan deadline stops before a Worker task or provider attempt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: TimeoutRecordingAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()
    expired = System.system_time(:millisecond) - 1

    context =
      context
      |> Map.put(:fanout_deadline_unix_ms, expired)
      |> Map.put(:fanout_grounding, %{grounding | fanout_deadline_unix_ms: expired})

    assert {:error, :fanout_plan_deadline_exhausted} =
             JidoAdapter.run(DirectAnswer, %{text: grounding.direct_answer_text}, context, [])

    refute_receive {:quality_deadline_context, _timeout, _worker_deadline, _review_deadline}
  end

  test "the Worker owner rejects and kills a draft that returns after its absolute deadline" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: BlockingDraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()
    deadline = System.system_time(:millisecond) + 500

    context =
      context
      |> Map.put(:fanout_deadline_unix_ms, deadline)
      |> Map.put(:fanout_grounding, %{grounding | fanout_deadline_unix_ms: deadline})

    assert {:error, :worker_timeout} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: PhaseCritic
             )

    assert_receive :blocking_draft_started
    refute_receive :blocking_draft_returned, 600
    refute_receive {:worker_critic_call, _phase, _group}
  end

  test "critic unavailability cannot promote the draft to checked completion" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{
               provider_call_count: 1,
               reason: :critic_implementation_failed
             }}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_critic: UnavailableCritic
             )

    assert_receive {:draft_provider_call, _prompt, _policy}
    assert_receive {:critic_unavailable, _group}
  end

  test "excess critic provider attempts fail closed with their exact physical count" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PhaseAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()
    context = Map.put(context, :critic_statuses, %{initial: %{}})

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 5, reason: :quality_provider_attempt_bound_exceeded}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: DoubleAttemptCritic
             )

    assert_receive {:worker_critic_call, :initial, "coverage_fidelity"}
    assert_receive {:worker_critic_call, :initial, "safety_consistency"}
  end

  test "post-review receipt rejection retains all three spent provider calls" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PhaseAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    context =
      context
      |> Map.put(:objective_id, nil)
      |> Map.put(:critic_statuses, %{initial: %{}})

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 3, reason: :invalid_quality_receipt_binding}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: PhaseCritic
             )

    assert_receive {:worker_critic_call, :initial, "coverage_fidelity"}
    assert_receive {:worker_critic_call, :initial, "safety_consistency"}
  end

  test "cancellation arriving after the draft prevents review and preserves count one" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: CancellingDraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    token = CancelToken.new()
    {grounding, context} = quality_worker_context()
    context = Map.put(context, :cancel_token, token)

    assert {:error, {:fanout_worker_unresolved, %{provider_call_count: 1, reason: :cancelled}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context
             )

    assert_receive :draft_cancelled_before_review
    refute_receive {:worker_critic_call, _phase, _group}
  end

  test "cancellation arriving during a critic round prevents checked completion" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    token = CancelToken.new()
    {grounding, context} = quality_worker_context()
    context = Map.put(context, :cancel_token, token)

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 1, reason: :critic_implementation_failed}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_critic: CancellingCritic
             )

    assert_receive {:draft_provider_call, _prompt, _policy}
    assert_receive {:critic_cancelled_run, _group}
  end

  test "ordinary DirectAnswer remains one provider call with no worker policy, review, or receipt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: OrdinaryAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    assert {:ok, %{adapter: :jido, response: response} = result} =
             Worker.run(
               "direct_answer",
               %{text: "Answer this ordinary request."},
               %{
                 user_id: "ordinary-user",
                 operator_id: "ordinary-user",
                 actor: "ordinary-user",
                 channel: "test",
                 surface: "test",
                 test_pid: self(),
                 objective_id: "ordinary-objective",
                 step_id: "ordinary-step"
               }
             )

    assert response.message == "Ordinary one-call answer."
    assert result.quality_receipt == nil
    assert_receive {:ordinary_provider_call, nil}
    refute_receive {:worker_critic_call, _phase, _group}
  end

  test "phase-separated Worker accepts an unchanged draft after two independent critics" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PhaseAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    context =
      Map.put(context, :critic_statuses, %{
        initial: %{
          "coverage_fidelity" => "satisfied",
          "safety_consistency" => "satisfied"
        }
      })

    assert {:ok, %{adapter: :jido, response: response, quality_receipt: receipt}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_critic: PhaseCritic
             )

    assert response.message == "Initial phase-separated draft."
    assert receipt["version"] == 2
    assert receipt["draft_call_count"] == 1
    assert receipt["initial_critic_call_count"] == 2
    assert receipt["revision_call_count"] == 0
    assert receipt["final_critic_call_count"] == 0
    assert receipt["provider_call_count"] == 3
    assert receipt["final_assessment_sha256"] == nil
    assert receipt["accepted_assessment_sha256"] == receipt["initial_assessment_sha256"]

    assert_receive {:worker_generation_call, :draft}
    assert_receive {:worker_critic_call, :initial, "coverage_fidelity"}
    assert_receive {:worker_critic_call, :initial, "safety_consistency"}
    refute_receive {:worker_generation_call, :revision}
    refute_receive {:worker_critic_call, :final, _group}
  end

  test "phase-separated Worker revises once and uses a fresh critic pair for acceptance" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PhaseAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    context =
      Map.put(context, :critic_statuses, %{
        initial: %{
          "coverage_fidelity" => "violated",
          "safety_consistency" => "satisfied"
        },
        final: %{
          "coverage_fidelity" => "satisfied",
          "safety_consistency" => "satisfied"
        }
      })

    assert {:ok, %{adapter: :jido, response: response, quality_receipt: receipt}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_critic: PhaseCritic
             )

    assert response.message == "Revised phase-separated answer."
    assert receipt["version"] == 2
    assert receipt["draft_call_count"] == 1
    assert receipt["initial_critic_call_count"] == 2
    assert receipt["revision_call_count"] == 1
    assert receipt["final_critic_call_count"] == 2
    assert receipt["provider_call_count"] == 6
    assert receipt["accepted_assessment_sha256"] == receipt["final_assessment_sha256"]
    assert receipt["accepted_assessment_sha256"] != receipt["initial_assessment_sha256"]

    assert_receive {:worker_generation_call, :draft}
    assert_receive {:worker_critic_call, :initial, "coverage_fidelity"}
    assert_receive {:worker_critic_call, :initial, "safety_consistency"}
    assert_receive {:worker_generation_call, :revision}
    assert_receive {:worker_critic_call, :final, "coverage_fidelity"}
    assert_receive {:worker_critic_call, :final, "safety_consistency"}
  end

  test "final critics and receipt bind the exact redacted bounded revision bytes" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PhaseAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    raw_revision = LongRedactableAnswerer.message()
    expected = ObservationSummary.normalize(raw_revision)
    refute expected =~ "AIzaSyDUMMYSecretShapeForAudit59"
    assert expected =~ "[REDACTED]"
    {grounding, context} = quality_worker_context()

    context =
      context
      |> Map.put(:record_critic_candidates, true)
      |> Map.put(:worker_phase_messages, %{revision: raw_revision})
      |> Map.put(:critic_statuses, %{
        initial: %{"coverage_fidelity" => "violated"},
        final: %{}
      })

    assert {:ok, %{response: %{message: ^expected}, quality_receipt: receipt}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: PhaseCritic
             )

    assert receipt["provider_call_count"] == 6
    assert receipt["final_answer_sha256"] == sha256(expected)
    assert_receive {:worker_critic_candidate, :final, "coverage_fidelity", ^expected}
    assert_receive {:worker_critic_candidate, :final, "safety_consistency", ^expected}
  end

  test "an empty normalized revision stops at call four before final critics" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PhaseAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    context =
      context
      |> Map.put(:worker_phase_messages, %{revision: " \n\t "})
      |> Map.put(:critic_statuses, %{initial: %{"coverage_fidelity" => "violated"}})

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 4, reason: :quality_model_revision_unavailable}}} =
             Worker.run("direct_answer", %{text: grounding.direct_answer_text}, context,
               quality_critic: PhaseCritic
             )

    assert_receive {:worker_generation_call, :revision}
    refute_receive {:worker_critic_call, :final, _group}
  end

  test "a revised answer that fails fresh verification remains honestly unresolved" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: PhaseAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    context =
      Map.put(context, :critic_statuses, %{
        initial: %{"coverage_fidelity" => "violated"},
        final: %{"safety_consistency" => "unresolved"}
      })

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 6, reason: :quality_review_unresolved}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_critic: PhaseCritic
             )

    assert_receive {:worker_generation_call, :draft}
    assert_receive {:worker_generation_call, :revision}
    assert_receive {:worker_critic_call, :initial, "coverage_fidelity"}
    assert_receive {:worker_critic_call, :initial, "safety_consistency"}
    assert_receive {:worker_critic_call, :final, "coverage_fidelity"}
    assert_receive {:worker_critic_call, :final, "safety_consistency"}
  end

  defp assert_post_dispatch_draft_failure(answerer, provider_message) do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: answerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    {grounding, context} = quality_worker_context()

    assert {:error,
            {:fanout_worker_unresolved,
             %{provider_call_count: 1, reason: :quality_model_draft_unavailable}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context
             )

    assert_receive ^provider_message
    refute_receive ^provider_message
    refute_receive {:worker_critic_call, _phase, _group}
  end

  defp quality_worker_context do
    assert {:ok, budget} = Budget.resolve(2, 1)
    deadline = System.system_time(:millisecond) + 60_000

    grounding = %{
      source: :conversation_manager,
      original_request: "Prepare two independent analyses.",
      child_objective: "Analyze the first mechanism.",
      expected_result: "Cover its behavior and tradeoffs.",
      steering: nil,
      decision_text: nil,
      direct_answer_text: "legacy compiled task input",
      action_text: nil,
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline
    }

    context = %{
      user_id: "quality-worker-user",
      operator_id: "quality-worker-user",
      actor: "quality-worker-user",
      channel: "test",
      surface: "test",
      test_pid: self(),
      objective_id: "objective-#{System.unique_integer([:positive])}",
      step_id: "step-#{System.unique_integer([:positive])}",
      objective_run_attempt: 1,
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline,
      fanout_grounding: grounding
    }

    {grounding, context}
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end
end
