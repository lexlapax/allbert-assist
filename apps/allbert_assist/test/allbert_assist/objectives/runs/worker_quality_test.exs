defmodule AllbertAssist.Objectives.Runs.WorkerQualityTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer.Policy, as: DirectAnswerPolicy
  alias AllbertAssist.Intent.FanoutPlan
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

      rule_results =
        QualityPolicy.rule_ids()
        |> Enum.map(&%{"rule_id" => &1, "verdict" => "satisfied"})

      {:ok,
       %Response{
         id: "quality-review",
         model: "fixture-quality-model",
         context: prompt,
         finish_reason: :stop,
         object: %{
           "final_answer" => "The reviewed child answer.",
           "verdict" => "accepted",
           "rule_results" => rule_results
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
             ~w[child_objective expected_result original_request rules source steering version]

    assert contract["version"] == 1
    assert contract["source"] == "conversation_manager"
    assert contract["original_request"] == grounding.original_request
    assert contract["child_objective"] == grounding.child_objective
    assert contract["expected_result"] == grounding.expected_result
    assert contract["steering"] == nil

    direct_answer_ids = Enum.map(DirectAnswerPolicy.rule_specs(), &Atom.to_string(&1.id))

    assert Enum.take(Enum.map(contract["rules"], & &1["id"]), length(direct_answer_ids)) ==
             direct_answer_ids

    assert Enum.map(contract["rules"], & &1["id"]) == QualityPolicy.rule_ids()

    assert {:ok, digest} = QualityPolicy.digest(contract)

    assert digest ==
             sha256("allbert:fanout-worker-quality-task:v1\0" <> CanonicalJSON.encode(contract))

    assert {:ok, draft_prompt} = QualityPolicy.draft_prompt(contract)
    assert draft_prompt =~ "Allbert bounded fan-out child quality task"
    assert draft_prompt =~ CanonicalJSON.encode(contract)
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
      rule_catalog_version: 1,
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
                    _prompt, _schema, opts}

    assert opts[:max_tokens] == 512
    assert opts[:receive_timeout] == prepared.timeout_ms
    assert opts[:openai_structured_output_mode] == :json_schema
    assert opts[:json_repair] == false
  end

  test "review evidence is rejected when its final bytes require normalization or its rule rows are malformed" do
    satisfied_results =
      Enum.map(QualityPolicy.rule_ids(), &%{"rule_id" => &1, "verdict" => "satisfied"})

    for invalid_answer <- [
          String.duplicate("界", 2_001),
          "token=Bearer DUMMYSecretShapeForAudit59 completed"
        ] do
      assert {:error, :invalid_quality_review} =
               QualityPolicy.validate_review(%{
                 "final_answer" => invalid_answer,
                 "verdict" => "accepted",
                 "rule_results" => satisfied_results
               })
    end

    assert {:error, :invalid_quality_review} =
             QualityPolicy.validate_review(%{
               "final_answer" => "Valid bounded bytes.",
               "verdict" => "accepted",
               "rule_results" => ["not-a-rule-map"]
             })
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
      rule_catalog_version: 1,
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

  test "review rule evidence rejects reordering, duplicates, extras, and extra row fields" do
    valid = Enum.map(QualityPolicy.rule_ids(), &%{"rule_id" => &1, "verdict" => "satisfied"})

    [first | rest] = valid

    invalid_sets = [
      Enum.reverse(valid),
      [first, first | rest],
      valid ++ [%{"rule_id" => "invented_rule", "verdict" => "satisfied"}],
      [Map.put(first, "critique", "free-form") | rest]
    ]

    for rule_results <- invalid_sets do
      assert {:error, :invalid_quality_review} =
               QualityPolicy.validate_review(%{
                 "final_answer" => "Bounded reviewed answer.",
                 "verdict" => "accepted",
                 "rule_results" => rule_results
               })
    end
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
end
