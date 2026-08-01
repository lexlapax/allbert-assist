defmodule AllbertAssist.Objectives.Runs.WorkerJidoAdapterTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Runs.{CancelToken, Worker}
  alias AllbertAssist.Objectives.Runs.Worker.Commands.Execute
  alias AllbertAssist.Objectives.Runs.Worker.Commands.ReviewAndRevise
  alias AllbertAssist.Objectives.Runs.Worker.{QualityPolicy, QualityReceipt}

  defmodule AcceptingReviewer do
    @config_digest String.duplicate("a", 64)

    def prepare(contract, draft, context) do
      send(context.test_pid, {:review_prepared, contract, draft})
      {:ok, %{reviewer_config_sha256: @config_digest}}
    end

    def invoke(%{reviewer_config_sha256: @config_digest}, context) do
      send(context.test_pid, :review_invoked)

      rule_results =
        AllbertAssist.Objectives.Runs.Worker.QualityPolicy.rule_ids()
        |> Enum.map(&%{"rule_id" => &1, "verdict" => "satisfied"})

      {:ok,
       %{
         final_answer: "The reviewed and revised child answer.",
         verdict: "accepted",
         failed_rule_ids: [],
         rule_results: rule_results,
         reviewer_config_sha256: @config_digest
       }}
    end
  end

  defmodule DraftAnswerer do
    def answer(text, context) do
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

  defmodule FailingDraftAnswerer do
    def answer(_text, context) do
      send(context.test_pid, :draft_provider_failed)
      {:error, :provider_unavailable}
    end
  end

  defmodule CancellingDraftAnswerer do
    alias AllbertAssist.Objectives.Runs.CancelToken

    def answer(_text, context) do
      :ok = CancelToken.cancel(context.cancel_token)
      send(context.test_pid, :draft_cancelled_before_review)

      {:ok,
       %{message: "Draft completed while cancellation arrived.", diagnostic: %{status: :used}}}
    end
  end

  defmodule DeniedReviewer do
    def prepare(_contract, _draft, context) do
      send(context.test_pid, :review_prepare_denied)
      {:error, :transport_denied}
    end

    def invoke(_prepared, context) do
      send(context.test_pid, :unexpected_denied_review_invoke)
      {:error, :must_not_run}
    end
  end

  defmodule DeadlineReviewer do
    def prepare(_contract, _draft, context) do
      send(context.test_pid, :review_deadline_checked)
      {:error, :fanout_plan_deadline_exhausted}
    end

    def invoke(_prepared, context) do
      send(context.test_pid, :unexpected_deadline_review_invoke)
      {:error, :must_not_run}
    end
  end

  defmodule CancellingReviewer do
    @digest String.duplicate("f", 64)

    def prepare(_contract, _draft, _context),
      do: {:ok, %{reviewer_config_sha256: @digest}}

    def invoke(_prepared, context) do
      :ok = AllbertAssist.Objectives.Runs.CancelToken.cancel(context.cancel_token)
      send(context.test_pid, :review_completed_during_cancellation)

      rule_results =
        AllbertAssist.Objectives.Runs.Worker.QualityPolicy.rule_ids()
        |> Enum.map(&%{"rule_id" => &1, "verdict" => "satisfied"})

      {:ok,
       %{
         final_answer: "A review result that must not survive cancellation.",
         verdict: "accepted",
         failed_rule_ids: [],
         rule_results: rule_results,
         reviewer_config_sha256: @digest
       }}
    end
  end

  defmodule InvokedFailureReviewer do
    def prepare(_contract, _draft, _context),
      do: {:ok, %{reviewer_config_sha256: String.duplicate("c", 64)}}

    def invoke(_prepared, context) do
      send(context.test_pid, {:reviewer_invoked_branch, __MODULE__})
      {:error, :timeout}
    end
  end

  defmodule MalformedReviewer do
    @digest String.duplicate("d", 64)
    def prepare(_contract, _draft, _context), do: {:ok, %{reviewer_config_sha256: @digest}}

    def invoke(_prepared, context) do
      send(context.test_pid, {:reviewer_invoked_branch, __MODULE__})

      {:ok,
       %{
         final_answer: "Malformed evidence",
         verdict: "accepted",
         failed_rule_ids: [],
         rule_results: "not-a-list",
         reviewer_config_sha256: @digest
       }}
    end
  end

  defmodule UnresolvedReviewer do
    @digest String.duplicate("e", 64)
    def prepare(_contract, _draft, _context), do: {:ok, %{reviewer_config_sha256: @digest}}

    def invoke(_prepared, context) do
      send(context.test_pid, {:reviewer_invoked_branch, __MODULE__})

      [first | rest] = AllbertAssist.Objectives.Runs.Worker.QualityPolicy.rule_ids()

      rule_results =
        [%{"rule_id" => first, "verdict" => "unsatisfied"}] ++
          Enum.map(rest, &%{"rule_id" => &1, "verdict" => "satisfied"})

      {:ok,
       %{
         final_answer: "Still unresolved.",
         verdict: "unresolved",
         failed_rule_ids: [first],
         rule_results: rule_results,
         reviewer_config_sha256: @digest
       }}
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

  test "review-and-revise accepts one model draft and emits a bound transient receipt" do
    assert {:ok, contract} =
             QualityPolicy.build(%{
               source: :conversation_manager,
               original_request: "Prepare two independent analyses.",
               child_objective: "Analyze the first mechanism.",
               expected_result: "Cover its behavior and tradeoffs.",
               steering: nil
             })

    assert {:ok, task_digest} = QualityPolicy.digest(contract)

    state = %{
      status: :draft,
      objective_id: "objective-reviewed",
      step_id: "step-reviewed",
      provider_call_count: 1,
      task_contract: contract,
      task_contract_sha256: task_digest,
      draft_response: %{
        message: "Initial model draft.",
        status: :completed,
        direct_answer: %{source: :model}
      },
      last_command: :execute,
      last_result: {:ok, :draft}
    }

    params = %{
      reviewer: AcceptingReviewer,
      runner_context: %{test_pid: self()}
    }

    assert {:ok, accepted} = ReviewAndRevise.run(params, %{state: state})
    assert_receive {:review_prepared, ^contract, "Initial model draft."}
    assert_receive :review_invoked

    assert accepted.status == :accepted
    assert accepted.provider_call_count == 2
    assert accepted.draft_response == nil
    assert accepted.error == nil
    assert accepted.last_command == :review_and_revise
    assert {:ok, %{response: response, quality_receipt: receipt}} = accepted.last_result
    assert response.message == "The reviewed and revised child answer."
    refute Map.has_key?(response, :fanout_worker)

    assert :ok =
             QualityReceipt.validate(receipt, %{
               objective_id: state.objective_id,
               step_id: state.step_id,
               task_contract_sha256: task_digest,
               final_answer: response.message
             })
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

  test "the Worker runs sequential draft and review commands and returns only the accepted response plus receipt" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

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
      objective_id: "objective-sequential",
      step_id: "step-sequential",
      objective_run_attempt: 1,
      fanout_budget: budget,
      fanout_deadline_unix_ms: deadline,
      fanout_grounding: grounding
    }

    assert {:ok, %{adapter: :jido, response: response, quality_receipt: receipt}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_reviewer: AcceptingReviewer
             )

    assert_receive {:draft_provider_call, draft_prompt, _closed_policy}
    assert draft_prompt =~ "Allbert bounded fan-out child quality task"
    assert_receive {:review_prepared, _contract, "Initial model draft."}
    assert_receive :review_invoked

    assert response.message == "The reviewed and revised child answer."
    refute Map.has_key?(response, :fanout_worker)
    assert receipt["provider_call_count"] == 2
    assert receipt["verdict"] == "accepted"
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
               context,
               quality_reviewer: AcceptingReviewer
             )

    refute_receive {:draft_provider_call, _prompt, _policy}
    refute_receive {:review_prepared, _contract, _draft}
    refute_receive :review_invoked
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
               context,
               quality_reviewer: AcceptingReviewer
             )

    assert_receive :draft_provider_failed
    refute_receive {:review_prepared, _contract, _draft}
    refute_receive :review_invoked
  end

  test "reviewer preparation denial preserves the one-call draft count" do
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
               reason: {:quality_reviewer_unavailable, :transport_denied}
             }}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_reviewer: DeniedReviewer
             )

    assert_receive {:draft_provider_call, _prompt, _policy}
    assert_receive :review_prepare_denied
    refute_receive :unexpected_denied_review_invoke
  end

  test "every invoked reviewer failure or unresolved result reports the exact two-call count" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    for reviewer <- [InvokedFailureReviewer, MalformedReviewer, UnresolvedReviewer] do
      {grounding, context} = quality_worker_context()

      assert {:error,
              {:fanout_worker_unresolved, %{provider_call_count: 2, reason: _closed_reason}}} =
               Worker.run(
                 "direct_answer",
                 %{text: grounding.direct_answer_text},
                 context,
                 quality_reviewer: reviewer
               )

      assert_receive {:draft_provider_call, _prompt, _policy}
      assert_receive {:reviewer_invoked_branch, ^reviewer}
    end
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
               context,
               quality_reviewer: AcceptingReviewer
             )

    assert_receive :draft_cancelled_before_review
    refute_receive {:review_prepared, _contract, _draft}
    refute_receive :review_invoked
  end

  test "cancellation arriving during review prevents accepted completion and preserves count two" do
    Application.put_env(:allbert_assist, DirectAnswer, answerer: DraftAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    token = CancelToken.new()
    {grounding, context} = quality_worker_context()
    context = Map.put(context, :cancel_token, token)

    assert {:error, {:fanout_worker_unresolved, %{provider_call_count: 2, reason: :cancelled}}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_reviewer: CancellingReviewer
             )

    assert_receive {:draft_provider_call, _prompt, _policy}
    assert_receive :review_completed_during_cancellation
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
               },
               quality_reviewer: AcceptingReviewer
             )

    assert response.message == "Ordinary one-call answer."
    refute Map.has_key?(result, :quality_receipt)
    assert_receive {:ordinary_provider_call, nil}
    refute_receive {:review_prepared, _contract, _draft}
    refute_receive :review_invoked
  end

  test "deadline exhaustion after the draft spends no review call and reports count one" do
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
               reason: {:quality_reviewer_unavailable, :fanout_plan_deadline_exhausted}
             }}} =
             Worker.run(
               "direct_answer",
               %{text: grounding.direct_answer_text},
               context,
               quality_reviewer: DeadlineReviewer
             )

    assert_receive {:draft_provider_call, _prompt, _policy}
    assert_receive :review_deadline_checked
    refute_receive :unexpected_deadline_review_invoke
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
end
