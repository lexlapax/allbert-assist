defmodule AllbertAssist.Objectives.Runs.WorkerQualityTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  @legacy_task_v1_sha256 "f0bbb60c11e684c33a96018e91e848244abdb02bd8489383852206577b46f1c6"
  @legacy_receipt_v1_sha256 "3d9bde95e3334ba01d9da7d42f9350d28a69c284af4f4301cc7cfcfdd770acf8"
  @legacy_event_v1_json ~S"""
  {
    "quality_receipt": {
      "failed_rule_ids": [],
      "final_answer_sha256": "d4c737f7c54c8c52accb5ce9efa5aac4fdda8f24a04f801cd14c2fa8fc7566e0",
      "objective_id_sha256": "5cc7d5b0d5578ffe5f5793b667f123709a0916bd58dbf5f9514cbc1ffbb6df5f",
      "provider_call_count": 2,
      "reviewer_config_sha256": "2222222222222222222222222222222222222222222222222222222222222222",
      "rule_catalog_version": 1,
      "step_id_sha256": "2ff994001718bfd4fe63aa1d61db00846a05c04f97133a2d6b50670a4b4f09ae",
      "task_contract_sha256": "f0bbb60c11e684c33a96018e91e848244abdb02bd8489383852206577b46f1c6",
      "verdict": "accepted",
      "version": 1
    },
    "step_id": "legacy-step",
    "step_status": "completed"
  }
  """

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy, as: DirectAnswerPolicy
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.{Budget, ReviewProtocol}
  alias AllbertAssist.Objectives.Steering

  alias AllbertAssist.Objectives.Runs.Worker.Agent, as: WorkerAgent
  alias AllbertAssist.Objectives.Runs.Worker.{Grounding, QualityPolicy, QualityReceipt}

  alias AllbertAssist.Objectives.Runs.Worker.Commands.Revise

  test "Worker exposes only the phase-separated quality transitions" do
    assert WorkerAgent.signal_routes() == [
             {"allbert.objectives.worker.execute",
              AllbertAssist.Objectives.Runs.Worker.Commands.Execute},
             {"allbert.objectives.worker.review_round",
              AllbertAssist.Objectives.Runs.Worker.Commands.ReviewRound},
             {"allbert.objectives.worker.revise",
              AllbertAssist.Objectives.Runs.Worker.Commands.Revise}
           ]
  end

  test "one typed child contract composes the existing DirectAnswer rules in declared order" do
    grounding = %{
      source: :conversation_manager,
      original_request: "Prepare an architecture brief with two requested dimensions.",
      child_objective: "Analyze the first requested dimension.",
      expected_result: "Explain the mechanism and its important tradeoffs.",
      steering: nil
    }

    assert {:ok, contract} = QualityPolicy.build(grounding)

    assert Map.keys(contract) |> Enum.sort() ==
             ~w[child_objective completion_obligation expected_result original_request rules source steering version]

    assert contract["version"] == 2
    assert contract["source"] == "conversation_manager"
    assert contract["original_request"] == grounding.original_request
    assert contract["child_objective"] == grounding.child_objective
    assert contract["expected_result"] == grounding.expected_result

    assert contract["completion_obligation"] == %{
             "version" => 1,
             "requirement_sources" => ["child_objective", "expected_result"],
             "satisfaction_policy" => "all_explicit_requirements_present_and_supported",
             "missing_required_evidence_outcome" => "unresolved"
           }

    assert contract["steering"] == nil

    direct_answer_ids = Enum.map(DirectAnswerPolicy.rule_specs(), &Atom.to_string(&1.id))

    assert Enum.take(Enum.map(contract["rules"], & &1["id"]), length(direct_answer_ids)) ==
             direct_answer_ids

    assert Enum.map(contract["rules"], & &1["id"]) == QualityPolicy.rule_ids()
    assert "completion_preconditions" in QualityPolicy.rule_ids()

    assert {:ok, digest} = QualityPolicy.digest(contract)

    assert digest ==
             sha256("allbert:fanout-worker-quality-task:v2\0" <> CanonicalJSON.encode(contract))

    assert {:ok, %{"1" => legacy_digest, "2" => ^digest}} =
             QualityPolicy.receipt_task_digests(contract)

    legacy_contract =
      contract
      |> Map.drop(["completion_obligation"])
      |> Map.put("version", 1)
      |> Map.update!(
        "rules",
        &Enum.reject(&1, fn rule ->
          rule["id"] == "completion_preconditions"
        end)
      )

    assert legacy_digest ==
             sha256(
               "allbert:fanout-worker-quality-task:v1\0" <>
                 CanonicalJSON.encode(legacy_contract)
             )

    assert {:ok, projection} = QualityPolicy.provider_projection(contract)

    assert Map.keys(projection) |> Enum.sort() ==
             ~w[child_objective completion_obligation expected_result original_request rule_catalog source steering version]

    refute Map.has_key?(projection, "rules")
    assert projection["version"] == 2
    assert projection["rule_catalog"]["version"] == 2

    assert projection["rule_catalog"]["sha256"] ==
             sha256(
               "allbert:fanout-worker-quality-rules:v2\0" <>
                 CanonicalJSON.encode(contract["rules"])
             )

    assert {:ok, draft_prompt} = QualityPolicy.draft_prompt(contract)
    assert draft_prompt =~ "Allbert bounded fan-out child quality task"
    assert draft_prompt =~ CanonicalJSON.encode(projection)
    refute draft_prompt =~ hd(contract["rules"])["instruction"]
  end

  test "verified steering replaces stale expected-result guidance and binds exact source bytes" do
    event_id = "019fb2a4-原文"
    directive = "Compare the two mechanisms without claiming an effect."

    grounding = %{
      source: :operator_steered,
      original_request: "Original operator request",
      child_objective: directive,
      expected_result: "Stale model-authored acceptance guidance",
      steering: %{directive_event_id: event_id, directive: directive}
    }

    assert {:ok, contract} = QualityPolicy.build(grounding)
    assert contract["child_objective"] == directive
    assert contract["expected_result"] == "Complete the operator-steered child task."

    assert contract["steering"] == %{
             "directive_event_id_sha256" => sha256(event_id),
             "directive_sha256" => sha256(directive)
           }

    assert {:ok, _digest} = QualityPolicy.digest(contract)
  end

  test "one content-free v2 receipt binds the phase-reviewed answer and exact terminal event" do
    accepted_assessment_sha256 = String.duplicate("4", 64)
    assert {:ok, group_catalog_sha256} = QualityPolicy.rule_group_catalog_sha256(1)

    binding = %{
      objective_id: "objective-原文",
      step_id: "step-019fb2a4",
      task_contract_sha256: String.duplicate("1", 64),
      rule_catalog_version: 2,
      reviewer_config_sha256: String.duplicate("2", 64),
      review_protocol_version: 1,
      critic_group_count: 2,
      rule_group_catalog_version: 1,
      rule_group_catalog_sha256: group_catalog_sha256,
      draft_call_count: 1,
      initial_critic_call_count: 2,
      revision_call_count: 0,
      final_critic_call_count: 0,
      provider_call_count: 3,
      initial_assessment_sha256: accepted_assessment_sha256,
      final_assessment_sha256: nil,
      accepted_assessment_sha256: accepted_assessment_sha256,
      verdict: "accepted",
      failed_rule_ids: [],
      final_answer: "A normalized reviewed answer."
    }

    assert {:ok, receipt} = QualityReceipt.build(binding)

    assert Map.keys(receipt) |> Enum.sort() ==
             ~w[accepted_assessment_sha256 critic_group_count draft_call_count failed_rule_ids final_answer_sha256 final_assessment_sha256 final_critic_call_count initial_assessment_sha256 initial_critic_call_count objective_id_sha256 provider_call_count review_protocol_version reviewer_config_sha256 revision_call_count rule_catalog_version rule_group_catalog_sha256 rule_group_catalog_version step_id_sha256 task_contract_sha256 verdict version]

    assert receipt["version"] == 2
    assert receipt["objective_id_sha256"] == sha256(binding.objective_id)
    assert receipt["step_id_sha256"] == sha256(binding.step_id)
    assert receipt["final_answer_sha256"] == sha256(binding.final_answer)
    assert :ok = QualityReceipt.validate(receipt, binding)
    assert :ok = QualityReceipt.validate_current(receipt, binding)

    assert {:ok, receipt_digest} = QualityReceipt.digest(receipt)

    assert receipt_digest ==
             sha256("allbert:fanout-worker-quality-receipt:v2\0" <> CanonicalJSON.encode(receipt))

    event_payload = %{
      "quality_receipt" => receipt,
      "step_id" => binding.step_id,
      "step_status" => "completed"
    }

    assert {:ok, ^receipt, ^receipt_digest} =
             QualityReceipt.from_event_payload(event_payload, binding)

    revised_binding = %{
      binding
      | revision_call_count: 1,
        final_critic_call_count: 2,
        provider_call_count: 6,
        final_assessment_sha256: String.duplicate("5", 64),
        accepted_assessment_sha256: String.duplicate("5", 64)
    }

    assert {:ok, revised_receipt} = QualityReceipt.build(revised_binding)
    assert :ok = QualityReceipt.validate_current(revised_receipt, revised_binding)

    for invalid <- [
          %{binding | provider_call_count: 4},
          %{binding | rule_group_catalog_sha256: String.duplicate("3", 64)},
          %{binding | final_assessment_sha256: String.duplicate("5", 64)},
          %{revised_binding | accepted_assessment_sha256: accepted_assessment_sha256}
        ] do
      assert {:error, :invalid_quality_receipt_binding} = QualityReceipt.build(invalid)
    end
  end

  test "new receipt writes require catalog v2 while valid catalog-v1 receipts replay" do
    assert {:ok, contract} = quality_contract()

    assert {:ok, %{"1" => legacy_digest, "2" => current_digest} = task_digests} =
             QualityPolicy.receipt_task_digests(contract)

    assert legacy_digest == @legacy_task_v1_sha256

    binding = %{
      objective_id: "legacy-objective",
      step_id: "legacy-step",
      task_contract_sha256: current_digest,
      task_contract_sha256_by_rule_catalog_version: task_digests,
      final_answer: "A legacy reviewed answer."
    }

    legacy_receipt = Jason.decode!(@legacy_event_v1_json)["quality_receipt"]

    assert :ok = QualityReceipt.validate(legacy_receipt, binding)

    assert {:error, :invalid_quality_receipt} =
             QualityReceipt.validate_current(legacy_receipt, binding)

    assert {:ok, @legacy_receipt_v1_sha256} = QualityReceipt.digest(legacy_receipt)

    assert {:ok, ^legacy_receipt, _digest} =
             QualityReceipt.from_event_payload(@legacy_event_v1_json, binding)

    refute match?(
             {:ok, _receipt},
             QualityReceipt.build(%{
               objective_id: binding.objective_id,
               step_id: binding.step_id,
               task_contract_sha256: legacy_digest,
               rule_catalog_version: 1,
               reviewer_config_sha256: String.duplicate("2", 64),
               provider_call_count: 2,
               verdict: "accepted",
               failed_rule_ids: [],
               final_answer: binding.final_answer
             })
           )

    unknown_receipt = Map.put(legacy_receipt, "rule_catalog_version", 3)
    assert {:error, :invalid_quality_receipt} = QualityReceipt.validate(unknown_receipt, binding)
  end

  test "verified grounding exposes the exact original request and compiled child guidance" do
    original_request = "Prepare two independent architecture analyses and join them later."
    child_objective = "Analyze the first architecture mechanism."
    expected_result = "Cover isolation behavior and important tradeoffs."

    assert {:ok, child} =
             create_grounded_child(original_request, child_objective, expected_result)

    assert %{
             source: :conversation_manager,
             original_request: ^original_request,
             child_objective: ^child_objective,
             expected_result: ^expected_result,
             steering: nil
           } = Grounding.resolve(child)
  end

  test "revision rejects stale or mutated initial-review evidence before generation" do
    assert {:ok, contract} = quality_contract()
    assert {:ok, task_digest} = QualityPolicy.digest(contract)
    draft = "Initial exact draft bytes."
    assert {:ok, review} = phase_review(contract, draft, "violated")
    expected_config = review.reviewer_config_sha256

    base_state = %{
      status: :revision_required,
      objective_id: "objective-review-binding",
      step_id: "step-review-binding",
      provider_call_count: 3,
      task_contract: contract,
      task_contract_sha256: task_digest,
      draft_response: %{message: draft},
      initial_review: review,
      initial_reviewer_config_sha256: expected_config
    }

    mutated_states = [
      put_in(base_state, [:draft_response, :message], "Changed draft bytes."),
      put_in(
        base_state,
        [:initial_review, :source_sha256, "candidate"],
        String.duplicate("0", 64)
      ),
      put_in(base_state, [:initial_review, :assessments, Access.at(0), "status"], "satisfied"),
      put_in(base_state, [:initial_review, :revision_rule_ids], ["foreign_rule"]),
      put_in(base_state, [:initial_review, :reviewer_config_sha256], String.duplicate("f", 64))
    ]

    Enum.each(mutated_states, fn state ->
      assert {:ok,
              %{
                status: :unresolved,
                error: :invalid_quality_revision_transition,
                provider_call_count: 3
              }} = Revise.run(%{runner_context: %{}}, %{state: state})
    end)
  end

  test "the maximal identity receipt stays below the event payload bound and rejects key collisions" do
    accepted_assessment_sha256 = String.duplicate("c", 64)
    assert {:ok, group_catalog_sha256} = QualityPolicy.rule_group_catalog_sha256(1)

    binding = %{
      objective_id: String.duplicate("o", 80),
      step_id: String.duplicate("s", 80),
      task_contract_sha256: String.duplicate("a", 64),
      rule_catalog_version: 2,
      reviewer_config_sha256: String.duplicate("b", 64),
      review_protocol_version: 1,
      critic_group_count: 2,
      rule_group_catalog_version: 1,
      rule_group_catalog_sha256: group_catalog_sha256,
      draft_call_count: 1,
      initial_critic_call_count: 2,
      revision_call_count: 0,
      final_critic_call_count: 0,
      provider_call_count: 3,
      initial_assessment_sha256: accepted_assessment_sha256,
      final_assessment_sha256: nil,
      accepted_assessment_sha256: accepted_assessment_sha256,
      verdict: "accepted",
      failed_rule_ids: [],
      final_answer: String.duplicate("界", 2_000)
    }

    assert {:ok, receipt} = QualityReceipt.build(binding)

    payload = %{
      "quality_receipt" => receipt,
      "step_id" => binding.step_id,
      "step_status" => "completed"
    }

    encoded = Jason.encode!(payload)
    assert String.length(encoded) <= 2_000

    event_changeset =
      Event.changeset(%Event{}, %{
        id: String.duplicate("e", 80),
        objective_id: binding.objective_id,
        step_id: binding.step_id,
        kind: "run_completed",
        summary: "Worker quality receipt accepted.",
        payload: encoded,
        recorded_at: DateTime.utc_now()
      })

    assert event_changeset.valid?
    assert {:ok, ^receipt, _digest} = QualityReceipt.from_event_payload(encoded, binding)

    mutated_receipt =
      Map.put(receipt, "rule_group_catalog_sha256", String.duplicate("f", 64))

    assert {:error, :invalid_quality_receipt} =
             QualityReceipt.validate(mutated_receipt, binding)

    assert {:error, :invalid_quality_receipt} = QualityReceipt.digest(mutated_receipt)

    assert {:error, :invalid_quality_receipt_event} =
             QualityReceipt.from_event_payload(
               Map.put(payload, "quality_receipt", mutated_receipt),
               binding
             )

    collision = Map.put(payload, :step_id, binding.step_id)

    assert {:error, :invalid_quality_receipt_event} =
             QualityReceipt.from_event_payload(collision, binding)
  end

  test "verified durable steering supplies exact event and directive bytes to the quality contract" do
    original_request = "Prepare two independent architecture analyses."
    original_child = "Analyze the first mechanism."

    assert {:ok, child} =
             create_grounded_child(original_request, original_child, "Cover behavior.")

    directive = "Compare the first mechanism against its stated constraints."
    assert {:ok, %{directive_event: event}} = Steering.steer(child.user_id, child.id, directive)
    assert {:ok, steered} = Steering.apply_pending(child.id)

    assert %{
             source: :operator_steered,
             original_request: ^original_request,
             child_objective: ^directive,
             steering: %{directive_event_id: event_id, directive: ^directive}
           } = grounding = Grounding.resolve(steered)

    assert event_id == event.id
    assert {:ok, contract} = QualityPolicy.build(grounding)
    assert contract["expected_result"] == "Complete the operator-steered child task."
    assert contract["steering"]["directive_event_id_sha256"] == sha256(event.id)
    assert contract["steering"]["directive_sha256"] == sha256(directive)
  end

  defp sha256(value) do
    :sha256
    |> :crypto.hash(value)
    |> Base.encode16(case: :lower)
  end

  defp create_grounded_child(original_request, child_objective, expected_result) do
    plan_children = [
      %{
        title: child_objective,
        objective: child_objective,
        expected_result: expected_result
      },
      %{
        title: "Analyze the sibling mechanism.",
        objective: "Analyze the sibling mechanism.",
        expected_result: "Cover recovery behavior and important tradeoffs."
      }
    ]

    assert {:ok, compiled} = FanoutPlan.compile(original_request, plan_children, source: :model)
    assert {:ok, budget} = Budget.resolve(2, 1)

    plan =
      compiled
      |> FanoutPlan.provenance()
      |> Map.put("manager_attempts", 1)
      |> Map.put("budget", budget)
      |> Map.put("deadline_unix_ms", System.system_time(:millisecond) + 60_000)

    parent = %{
      user_id: "quality-worker-user",
      title: "Grounded worker quality fixture",
      objective: original_request,
      proposer_hint: %{"fanout_plan" => plan}
    }

    case Fanout.frame(parent, FanoutPlan.child_attrs(compiled)) do
      {:ok, %{children: [child, _sibling]}} -> {:ok, child}
      {:error, reason} -> {:error, reason}
    end
  end

  defp quality_contract do
    QualityPolicy.build(%{
      source: :conversation_manager,
      original_request: "Prepare two independent analyses.",
      child_objective: "Analyze the first mechanism.",
      expected_result: "Cover its behavior and tradeoffs.",
      steering: nil
    })
  end

  defp phase_review(contract, candidate, status) do
    with {:ok, protocol} <- QualityPolicy.review_protocol(),
         {:ok, sources} <-
           ReviewProtocol.bind_sources(
             %{"task_contract" => CanonicalJSON.encode(contract)},
             candidate
           ),
         group_results =
           Enum.map(protocol.groups, fn group ->
             %{
               "group_id" => group["id"],
               "assessments" =>
                 Enum.map(group["rule_ids"], fn rule_id ->
                   %{
                     "rule_id" => rule_id,
                     "status" => status,
                     "source_handles" => ["task_contract", "candidate"]
                   }
                 end)
             }
           end),
         {:ok, review} <- ReviewProtocol.merge(protocol, group_results, sources) do
      {:ok,
       review
       |> Map.put(:reviewer_config_sha256, String.duplicate("a", 64))
       |> Map.put(:provider_call_count, 2)}
    end
  end
end
