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
  alias AllbertAssist.Models.ClosedRuleEvidence
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Event
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Steering

  alias AllbertAssist.Objectives.Runs.Worker.{
    Grounding,
    QualityPolicy,
    QualityReceipt,
    ReqLLMReviewer
  }

  alias ReqLLM.Response

  defmodule FixtureModels do
    def for(:fanout_synthesis, _context) do
      {:ok,
       %{
         profile: %{
           name: "quality-review-profile",
           provider: "local_ollama",
           provider_endpoint_kind: "local_endpoint",
           provider_type: "openai_compatible",
           model: "fixture-quality-model",
           max_tokens: 1_024,
           timeout_ms: 60_000
         }
       }}
    end
  end

  defmodule AllowDisclosure do
    def authorize_transport(profile, context) do
      send(context.test_pid, {:quality_disclosure, profile.name})
      :ok
    end
  end

  defmodule RecordingReqLLM do
    alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

    def generate_object(model_spec, prompt, schema, opts) do
      send(
        Keyword.fetch!(opts, :test_pid),
        {:quality_review_call, model_spec, prompt, schema, opts}
      )

      {:ok,
       %Response{
         id: "quality-review",
         model: "fixture-quality-model",
         context: prompt,
         finish_reason: :stop,
         object: %{
           "final_answer" => "The reviewed child answer.",
           "rule_violations" => Map.new(QualityPolicy.rule_ids(), &{&1, false})
         }
       }}
    end
  end

  defmodule UnavailableReqLLM do
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

  test "one content-free receipt binds the reviewed answer and exact terminal event" do
    binding = %{
      objective_id: "objective-原文",
      step_id: "step-019fb2a4",
      task_contract_sha256: String.duplicate("1", 64),
      rule_catalog_version: 2,
      reviewer_config_sha256: String.duplicate("2", 64),
      provider_call_count: 2,
      verdict: "accepted",
      failed_rule_ids: [],
      final_answer: "A normalized reviewed answer."
    }

    assert {:ok, receipt} = QualityReceipt.build(binding)

    assert Map.keys(receipt) |> Enum.sort() ==
             ~w[failed_rule_ids final_answer_sha256 objective_id_sha256 provider_call_count reviewer_config_sha256 rule_catalog_version step_id_sha256 task_contract_sha256 verdict version]

    assert receipt["objective_id_sha256"] == sha256(binding.objective_id)
    assert receipt["step_id_sha256"] == sha256(binding.step_id)
    assert receipt["final_answer_sha256"] == sha256(binding.final_answer)
    assert :ok = QualityReceipt.validate(receipt, binding)
    assert :ok = QualityReceipt.validate_current(receipt, binding)

    assert {:ok, receipt_digest} = QualityReceipt.digest(receipt)

    assert receipt_digest ==
             sha256("allbert:fanout-worker-quality-receipt:v1\0" <> CanonicalJSON.encode(receipt))

    event_payload = %{
      "quality_receipt" => receipt,
      "step_id" => binding.step_id,
      "step_status" => "completed"
    }

    assert {:ok, ^receipt, ^receipt_digest} =
             QualityReceipt.from_event_payload(event_payload, binding)
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

  test "the task-resolved reviewer prepares before and then makes one bounded structured call" do
    assert {:ok, contract} =
             QualityPolicy.build(%{
               source: :conversation_manager,
               original_request: "Prepare two independent analyses.",
               child_objective: "Analyze the first mechanism.",
               expected_result: "Cover its behavior and tradeoffs.",
               steering: nil
             })

    context = %{
      models: FixtureModels,
      disclosure: AllowDisclosure,
      req_llm_client: RecordingReqLLM,
      test_pid: self(),
      fanout_deadline_unix_ms: System.system_time(:millisecond) + 60_000,
      fanout_worker_deadline_monotonic_ms: System.monotonic_time(:millisecond) + 5_000,
      model_max_output_tokens: 512
    }

    assert {:ok, prepared} = ReqLLMReviewer.prepare(contract, "Initial draft.", context)
    assert_receive {:quality_disclosure, "quality-review-profile"}
    refute_receive {:quality_review_call, _spec, _prompt, _schema, _opts}
    assert prepared.max_output_tokens == 512
    assert prepared.timeout_ms in 1..5_000
    assert byte_size(prepared.reviewer_config_sha256) == 64

    assert {:ok, reviewed} = ReqLLMReviewer.invoke(prepared, context)
    assert reviewed.final_answer == "The reviewed child answer."
    assert reviewed.verdict == "accepted"
    assert reviewed.failed_rule_ids == []
    assert reviewed.reviewer_config_sha256 == prepared.reviewer_config_sha256

    assert_receive {:quality_review_call, %{provider: :openai, id: "fixture-quality-model"},
                    prompt, schema, opts}

    assert schema == %{
             "type" => "object",
             "properties" => %{
               "final_answer" => %{
                 "type" => "string",
                 "description" => "The reviewed and, when needed, revised child answer itself."
               },
               "rule_violations" => %{
                 "type" => "object",
                 "properties" => Map.new(QualityPolicy.rule_ids(), &{&1, %{"type" => "boolean"}}),
                 "required" => QualityPolicy.rule_ids(),
                 "additionalProperties" => false
               }
             },
             "required" => ["final_answer", "rule_violations"],
             "additionalProperties" => false
           }

    [system_message, user_message] = prompt.messages
    system_text = Enum.map_join(system_message.content, & &1.text)
    user_text = Enum.map_join(user_message.content, & &1.text)
    assert system_text =~ ClosedRuleEvidence.violation_semantics()

    for rule <- QualityPolicy.rule_specs() do
      assert count_occurrences(system_text, rule.instruction) == 1
      refute user_text =~ rule.instruction
    end

    refute user_text =~ "\"rules\""

    assert opts[:max_tokens] == 512
    assert opts[:receive_timeout] == prepared.timeout_ms
    assert opts[:openai_structured_output_mode] == :json_schema
    assert opts[:json_repair] == false
  end

  test "closed violation evidence derives its verdict locally and rejects malformed transport" do
    no_violations = Map.new(QualityPolicy.rule_ids(), &{&1, false})

    for invalid_answer <- [
          String.duplicate("界", 2_001),
          "token=Bearer DUMMYSecretShapeForAudit59 completed"
        ] do
      assert {:error, :invalid_quality_review} =
               QualityPolicy.validate_review(%{
                 "final_answer" => invalid_answer,
                 "rule_violations" => no_violations
               })
    end

    completion_violation = Map.put(no_violations, "completion_preconditions", true)

    assert {:ok,
            %{
              verdict: "unresolved",
              failed_rule_ids: ["completion_preconditions"],
              rule_results: rule_results
            }} =
             QualityPolicy.validate_review(%{
               "final_answer" => "Required evidence was not supplied.",
               "rule_violations" => completion_violation
             })

    assert Enum.find(rule_results, &(&1["rule_id"] == "completion_preconditions")) == %{
             "rule_id" => "completion_preconditions",
             "verdict" => "unsatisfied"
           }

    refute Enum.find(rule_results, &(&1["rule_id"] == "memory_is_reference"))["verdict"] ==
             "unsatisfied"

    assert {:error, :invalid_quality_review} =
             QualityPolicy.validate_review(%{
               "final_answer" => "Valid bounded bytes.",
               "rule_violations" => Map.delete(no_violations, "memory_is_reference")
             })

    assert {:error, :invalid_quality_review} =
             QualityPolicy.validate_review(%{
               "final_answer" => "Valid bounded bytes.",
               "rule_violations" => Map.put(no_violations, "invented_rule", false)
             })

    assert {:error, :invalid_quality_review} =
             QualityPolicy.validate_review(%{
               "final_answer" => "Valid bounded bytes.",
               "rule_violations" => Map.put(no_violations, "memory_is_reference", "false")
             })

    for legacy_shape <- [
          %{"final_answer" => "Legacy", "verdict" => "accepted", "rule_results" => []},
          %{
            "final_answer" => "Legacy",
            "verdict" => "accepted",
            "rule_results" => [
              %{"rule_id" => "memory_is_reference", "verdict" => "unsatisfied"}
            ]
          }
        ] do
      assert {:error, :invalid_quality_review} = QualityPolicy.validate_review(legacy_shape)
    end
  end

  test "review preparation rejects an unavailable client before a provider call can be counted" do
    assert {:ok, contract} = quality_contract()

    context = %{
      models: FixtureModels,
      disclosure: AllowDisclosure,
      req_llm_client: UnavailableReqLLM,
      test_pid: self(),
      fanout_deadline_unix_ms: System.system_time(:millisecond) + 60_000,
      fanout_worker_deadline_monotonic_ms: System.monotonic_time(:millisecond) + 5_000,
      model_max_output_tokens: 512
    }

    assert {:error, :req_llm_unavailable} =
             ReqLLMReviewer.prepare(contract, "Initial draft.", context)

    refute_receive {:quality_review_call, _spec, _prompt, _schema, _opts}
  end

  test "review preparation fails when either governing deadline expired after the draft" do
    assert {:ok, contract} = quality_contract()

    now_unix = System.system_time(:millisecond)
    now_monotonic = System.monotonic_time(:millisecond)

    for {unix_deadline, monotonic_deadline} <- [
          {now_unix - 1, now_monotonic + 5_000},
          {now_unix + 60_000, now_monotonic - 1}
        ] do
      context = %{
        models: FixtureModels,
        disclosure: AllowDisclosure,
        req_llm_client: RecordingReqLLM,
        test_pid: self(),
        fanout_deadline_unix_ms: unix_deadline,
        fanout_worker_deadline_monotonic_ms: monotonic_deadline,
        model_max_output_tokens: 512
      }

      assert {:error, :fanout_plan_deadline_exhausted} =
               ReqLLMReviewer.prepare(contract, "Initial draft.", context)
    end

    refute_receive {:quality_review_call, _spec, _prompt, _schema, _opts}
  end

  test "the maximal identity receipt stays below the event payload bound and rejects key collisions" do
    binding = %{
      objective_id: String.duplicate("o", 80),
      step_id: String.duplicate("s", 80),
      task_contract_sha256: String.duplicate("a", 64),
      rule_catalog_version: 2,
      reviewer_config_sha256: String.duplicate("b", 64),
      provider_call_count: 2,
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

  defp count_occurrences(text, needle) do
    text
    |> String.split(needle)
    |> length()
    |> Kernel.-(1)
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
end
