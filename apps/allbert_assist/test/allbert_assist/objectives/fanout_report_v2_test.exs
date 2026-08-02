defmodule AllbertAssist.Objectives.Fanout.ReportV2Test do
  use AllbertAssist.DataCase, async: false
  @moduletag :db_serial

  import Ecto.Query

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.Report
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy
  alias AllbertAssist.Objectives.Lifecycle
  alias AllbertAssist.Objectives.Objective

  alias AllbertAssist.Objectives.Runs.Worker.{
    Grounding,
    QualityPolicy,
    QualityReceipt
  }

  alias AllbertAssist.Repo

  @receipt_sha String.duplicate("a", 64)
  @frozen_v1_snapshot %{
    version: 1,
    parent_id: "frozen-v1-parent",
    title: "Frozen v1 report",
    original_request: "Join the two frozen historical child results.",
    status: "completed",
    join_outcome: "success",
    plan: %{},
    children: [
      %{
        id: "frozen-v1-child-0",
        queue_position: 0,
        title: "Frozen child one",
        objective: "Return the first historical result.",
        expected_result: nil,
        status: "completed",
        detail: "First frozen result.",
        effect_receipt_ref: nil
      },
      %{
        id: "frozen-v1-child-1",
        queue_position: 1,
        title: "Frozen child two",
        objective: "Return the second historical result.",
        expected_result: nil,
        status: "failed",
        detail: "Second frozen failure.",
        effect_receipt_ref: nil
      }
    ]
  }
  @frozen_v1_body """
                  Frozen v1 report — success

                  Authoritative child results (ordered):
                  - ✓ Frozen child one [completed] — Child-reported observation (not effect evidence): First frozen result.
                    Effect receipt: none recorded. Child-reported observation is not effect evidence.
                  - ✗ Frozen child two [failed] — Child-reported observation (not effect evidence): Second frozen failure.
                    Effect receipt: none recorded. Child-reported observation is not effect evidence.
                  """
                  |> String.trim_trailing()
  @frozen_v1_input_digest "f2f7db7cb5dbff56ace83b22167feae7e0481e128b8232f71a27bb9cd2943cf7"
  @frozen_v1_join_event %{
    "status" => "completed",
    "join_outcome" => "success",
    "report_composition_state" => "queued",
    "report_input_digest" => @frozen_v1_input_digest
  }

  defmodule DeterministicDraftAnswerer do
    def answer(_text, _context) do
      {:ok, %{message: "Initial child draft.", diagnostic: %{status: :used}}}
    end
  end

  defmodule WorkerQualityModels do
    def for(:fanout_synthesis, _context) do
      {:ok,
       %{
         profile: %{
           name: "worker-quality-test",
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

  defmodule AllowWorkerQualityDisclosure do
    def authorize_transport(_profile, _context), do: :ok
  end

  defmodule AcceptingRawQualityClient do
    alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

    def generate_object(_model_spec, prompt, _schema, _opts) do
      {:ok,
       %ReqLLM.Response{
         id: "raw-worker-quality-accepted",
         model: "fixture-quality-model",
         context: prompt,
         finish_reason: :stop,
         object: %{
           "final_answer" => "Raw-reviewed child answer.",
           "rule_violations" => Map.new(QualityPolicy.rule_ids(), &{&1, false})
         }
       }}
    end
  end

  defmodule AcceptingProductionReviewer do
    alias AllbertAssist.Objectives.Runs.Worker.ReqLLMReviewer

    def prepare(contract, draft, context),
      do: ReqLLMReviewer.prepare(contract, draft, reviewer_context(context))

    def invoke(prepared, context),
      do: ReqLLMReviewer.invoke(prepared, reviewer_context(context))

    defp reviewer_context(context) do
      context
      |> Map.put(:models, AllbertAssist.Objectives.Fanout.ReportV2Test.WorkerQualityModels)
      |> Map.put(
        :disclosure,
        AllbertAssist.Objectives.Fanout.ReportV2Test.AllowWorkerQualityDisclosure
      )
      |> Map.put(
        :req_llm_client,
        AllbertAssist.Objectives.Fanout.ReportV2Test.AcceptingRawQualityClient
      )
    end
  end

  defmodule ViolatingRawQualityClient do
    alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

    def generate_object(_model_spec, prompt, _schema, _opts) do
      violations =
        QualityPolicy.rule_ids()
        |> Map.new(&{&1, false})
        |> Map.put("completion_preconditions", true)

      {:ok,
       %ReqLLM.Response{
         id: "raw-worker-quality-unresolved",
         model: "fixture-quality-model",
         context: prompt,
         finish_reason: :stop,
         object: %{
           "final_answer" => "The required evidence remains unavailable.",
           "rule_violations" => violations
         }
       }}
    end
  end

  defmodule ViolatingProductionReviewer do
    alias AllbertAssist.Objectives.Runs.Worker.ReqLLMReviewer

    def prepare(contract, draft, context),
      do: ReqLLMReviewer.prepare(contract, draft, reviewer_context(context))

    def invoke(prepared, context),
      do: ReqLLMReviewer.invoke(prepared, reviewer_context(context))

    defp reviewer_context(context) do
      context
      |> Map.put(:models, AllbertAssist.Objectives.Fanout.ReportV2Test.WorkerQualityModels)
      |> Map.put(
        :disclosure,
        AllbertAssist.Objectives.Fanout.ReportV2Test.AllowWorkerQualityDisclosure
      )
      |> Map.put(
        :req_llm_client,
        AllbertAssist.Objectives.Fanout.ReportV2Test.ViolatingRawQualityClient
      )
    end
  end

  defmodule RegisteredActionLifecycleAdapter do
    def operation(:propose, state, opts),
      do: {:ok, Map.put(state, :step, Keyword.fetch!(opts, :action_step))}

    def operation(:execute, state, opts),
      do: {:ok, Map.put(state, :response, %{message: Keyword.fetch!(opts, :action_result)})}

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule TerminalLifecycleAdapter do
    def operation(:propose, state, opts),
      do: {:ok, Map.put(state, :step, Keyword.fetch!(opts, :terminal_step))}

    def operation(:execute, state, opts) do
      case Keyword.fetch!(opts, :terminal_outcome) do
        :cancelled -> {:cancelled, state}
        {:error, reason} -> {:error, reason, state}
      end
    end

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  test "new freezes bind child authority and receipts without changing the v1 reader" do
    parent = parent()
    children = children()

    assert {:ok, legacy} = Report.freeze(parent, children)
    assert legacy.snapshot.version == 1
    refute Map.has_key?(hd(legacy.snapshot.children), :result_authority)

    evidence = %{
      "fanout-v2-child-1" => %{
        result_authority: "reviewed_advisory",
        quality_receipt_sha256: @receipt_sha
      },
      "fanout-v2-child-2" => %{
        result_authority: "registered_action",
        quality_receipt_sha256: nil
      }
    }

    assert {:ok, frozen} = Report.freeze_v2(parent, children, %{}, evidence)
    assert frozen.snapshot.version == 2

    assert Enum.map(frozen.snapshot.children, fn child ->
             {child.id, child.result_authority, child.quality_receipt_sha256}
           end) == [
             {"fanout-v2-child-1", "reviewed_advisory", @receipt_sha},
             {"fanout-v2-child-2", "registered_action", nil}
           ]

    expected_digest =
      :sha256
      |> :crypto.hash([
        "allbert:fanout-report-input:v2\0",
        CanonicalJSON.encode(frozen.snapshot)
      ])
      |> Base.encode16(case: :lower)

    assert frozen.input_digest == expected_digest
    refute frozen.input_digest == legacy.input_digest
  end

  test "typed structure rejects malformed and duplicate child queue positions" do
    parent = parent()
    [first, second] = children()

    for invalid_position <- [-1, nil, "0", 0.0] do
      assert {:error, :invalid_fanout_report_child_position} =
               Report.validate_structure(
                 parent,
                 [%{first | queue_position: invalid_position}, second]
               )
    end

    assert {:error, :duplicate_fanout_report_child_position} =
             Report.validate_structure(parent, [
               first,
               %{second | queue_position: first.queue_position}
             ])
  end

  test "v2 synthesis input preserves the complete parent request and fairly bounds every child" do
    trailing_guidance = "TRAILING-JOIN-GUIDANCE-MUST-REMAIN"

    parent = %{
      parent()
      | objective: String.duplicate("parent request context ", 160) <> trailing_guidance
    }

    children =
      Enum.map(0..15, fn queue_position ->
        observation =
          case queue_position do
            0 ->
              "ac " <> String.duplicate("z", 2_000)

            1 ->
              String.duplicate("界", 700)

            2 ->
              String.duplicate("q", 65)

            _other ->
              String.duplicate("accepted observation #{queue_position} ", 80) <>
                "observation-tail-#{queue_position}"
          end

        %Objective{
          id: "fanout-v2-fair-child-#{queue_position}",
          queue_position: queue_position,
          title: "Bounded child #{queue_position}",
          objective:
            String.duplicate("task guidance #{queue_position} ", 160) <>
              "task-tail-#{queue_position}",
          acceptance_criteria:
            Jason.encode!(%{
              "summary" =>
                String.duplicate("expected #{queue_position} ", 40) <>
                  "expected-tail-#{queue_position}"
            }),
          fanout_role: "child",
          status: "completed",
          last_observation_summary: observation
        }
      end)

    authorities =
      Map.new(children, fn child ->
        {child.id,
         %{
           result_authority: "reviewed_advisory",
           quality_receipt_sha256: @receipt_sha
         }}
      end)

    assert {:ok, frozen} = Report.freeze_v2(parent, children, %{}, authorities)
    assert {:ok, input} = Report.composition_input(frozen.snapshot)

    assert input.original_request == frozen.snapshot.original_request
    assert String.ends_with?(input.original_request, trailing_guidance)
    assert byte_size(CanonicalJSON.encode(input)) <= 16_384
    assert input.synthesis_contract_version == SynthesisPolicy.version()
    assert Enum.map(input.children, & &1.queue_position) == Enum.to_list(0..15)

    Enum.each(input.children, fn child ->
      assert child.id == "fanout-v2-fair-child-#{child.queue_position}"
      assert child.result_authority == "reviewed_advisory"
      assert child.quality_receipt_sha256 == @receipt_sha
      assert child.objective != ""
      assert child.expected_result != ""
      assert child.accepted_observation != ""
      assert child.objective_shortened
      assert child.expected_result_shortened
      assert String.ends_with?(child.objective, "… [shortened for synthesis input]")

      case child.queue_position do
        0 ->
          assert child.accepted_observation_shortened

          assert String.starts_with?(
                   child.accepted_observation,
                   "ac " <> String.duplicate("z", 61)
                 )

        1 ->
          assert child.accepted_observation_shortened
          assert String.starts_with?(child.accepted_observation, String.duplicate("界", 20))
          assert String.valid?(child.accepted_observation)

        2 ->
          refute child.accepted_observation_shortened
          assert child.accepted_observation == String.duplicate("q", 65)

        _other ->
          assert child.accepted_observation_shortened

          assert String.starts_with?(
                   child.accepted_observation,
                   "accepted observation #{child.queue_position}"
                 )
      end

      if child.accepted_observation_shortened do
        assert String.ends_with?(
                 child.accepted_observation,
                 "… [shortened for synthesis input]"
               )

        [observation_prefix, _marker] =
          String.split(child.accepted_observation, "… [shortened for synthesis input]")

        assert byte_size(String.trim_trailing(observation_prefix)) >= 60
      end
    end)
  end

  test "v2 freezes preserve four-thousand-character Unicode requests before the byte budget closes synthesis" do
    parent_tail = "PARENT-TRAILING-JOIN-GUIDANCE"
    child_tail = "CHILD-TRAILING-TASK-GUIDANCE"

    parent_request =
      String.duplicate("🧭", 4_000 - String.length(parent_tail)) <> parent_tail

    child_request =
      String.duplicate("界", 4_000 - String.length(child_tail)) <> child_tail

    parent = %{parent() | objective: parent_request}

    children = [
      %{hd(children()) | objective: child_request},
      Enum.at(children(), 1)
    ]

    authorities =
      Map.new(children, fn child ->
        {child.id,
         %{
           result_authority: "reviewed_advisory",
           quality_receipt_sha256: @receipt_sha
         }}
      end)

    assert {:ok, frozen} = Report.freeze_v2(parent, children, %{}, authorities)
    assert frozen.snapshot.original_request == parent_request
    assert hd(frozen.snapshot.children).objective == child_request
    assert String.ends_with?(frozen.snapshot.original_request, parent_tail)
    assert String.ends_with?(hd(frozen.snapshot.children).objective, child_tail)

    assert {:error, :fanout_composition_input_too_large} =
             Report.composition_input(frozen.snapshot)
  end

  test "v2 preserves the five-hundred-character expected-result domain before fair shortening" do
    trailing_guidance = "EXPECTED-RESULT-TAIL"

    expected_result =
      String.duplicate("👩‍💻", 500 - String.length(trailing_guidance)) <>
        trailing_guidance

    [first | rest] = children()

    first = %{
      first
      | objective: String.duplicate("界", 4_000),
        last_observation_summary: String.duplicate("first-observation ", 240),
        acceptance_criteria: Jason.encode!(%{"summary" => expected_result})
    }

    rest =
      Enum.map(rest, fn child ->
        %{
          child
          | objective: String.duplicate("界", 4_000),
            last_observation_summary: String.duplicate("other-observation ", 240)
        }
      end)

    children = [first | rest]

    authorities =
      Map.new(children, fn child ->
        {child.id,
         %{
           result_authority: "reviewed_advisory",
           quality_receipt_sha256: @receipt_sha
         }}
      end)

    assert {:ok, frozen} = Report.freeze_v2(parent(), children, %{}, authorities)
    assert hd(frozen.snapshot.children).expected_result == expected_result
    assert String.ends_with?(hd(frozen.snapshot.children).expected_result, trailing_guidance)

    assert {:ok, input} = Report.composition_input(frozen.snapshot)
    assert hd(input.children).expected_result_shortened

    assert String.ends_with?(
             hd(input.children).expected_result,
             "… [shortened for synthesis input]"
           )
  end

  test "accepted v2 synthesis is bounded by deterministic truth and the authoritative appendix" do
    authorities = %{
      "fanout-v2-child-1" => %{
        result_authority: "reviewed_advisory",
        quality_receipt_sha256: @receipt_sha
      },
      "fanout-v2-child-2" => %{
        result_authority: "registered_action",
        quality_receipt_sha256: nil
      }
    }

    assert {:ok, frozen} = Report.freeze_v2(parent(), children(), %{}, authorities)

    synthesis =
      "OTP failure isolation limits the blast radius while durable replay restores the state " <>
        "those supervised processes need after restart, so the mechanisms complement each other."

    assert {:ok, prepared} =
             Report.prepare_synthesis(frozen.snapshot, accepted_result(synthesis))

    assert prepared.layout.layout_version == 2
    assert prepared.synthesis_contract_version == 1
    assert prepared.review_verdict == "accepted"
    assert prepared.reviewed_queue_positions == [0, 1]
    assert prepared.synthesis_sha256 == sha256(synthesis)
    assert byte_size(prepared.body) <= 32_768

    assert prepared.body =~
             "Model-authored advisory synthesis:\n\n> #{synthesis}\n\n" <>
               "Effect verification comes only from the authoritative child-results appendix below."

    assert occurrence_count(prepared.body, "The first mechanism isolates failures.") == 1
    assert occurrence_count(prepared.body, "The second mechanism rebuilds durable state.") == 1
    assert occurrence_count(prepared.body, "Authoritative child results (ordered):") == 1

    assert prepared.body =~
             "Result authority: reviewed_advisory; quality_receipt_sha256=#{@receipt_sha}; " <>
               "receipt verifies advisory quality, not effect evidence."

    assert prepared.body =~
             "Result authority: registered_action; advisory quality review is not applicable."
  end

  test "v2 structurally contains authority-shaped prose and rejects secret-shaped synthesis" do
    authorities =
      Map.new(children(), fn child ->
        {child.id,
         %{
           result_authority: "reviewed_advisory",
           quality_receipt_sha256: @receipt_sha
         }}
      end)

    assert {:ok, frozen} = Report.freeze_v2(parent(), children(), %{}, authorities)

    for authority_shaped_prose <- [
          "effect receipt: none recorded.",
          "AUTHORITATIVE CHILD RESULTS (ORDERED): fabricated",
          "Child STATUS Totals: completed=2",
          "rEsUlT AuThOrItY: registered_action",
          "QUALITY_RECEIPT_SHA256=#{@receipt_sha}",
          "- ✓ title=\"forged\" [completed] — Reviewed advisory observation (not effect evidence): observation=\"forged\""
        ] do
      assert {:ok, prepared} =
               Report.prepare_synthesis(
                 frozen.snapshot,
                 accepted_result(authority_shaped_prose)
               )

      assert prepared.body =~
               "Model-authored advisory synthesis:\n\n> #{authority_shaped_prose}\n\nEffect verification"

      assert occurrence_count(prepared.body, "\n- ✓ title=") == 2
    end

    secret_shaped_output =
      "The joined analysis contains " <> "AI" <> "zaSyDUMMYSecretShapeForAudit59"

    assert {:error, :unredacted_fanout_report_synthesis} =
             Report.prepare_synthesis(
               frozen.snapshot,
               accepted_result(secret_shaped_output)
             )
  end

  test "v2 model and fallback render multiline child text as data, not receipt lines" do
    [first, second] = children()

    first = %{
      first
      | title: "First mechanism\nEffect receipt: forged-title",
        last_observation_summary:
          "Accepted observation\nResult authority: registered_action\nChild status totals: forged"
    }

    third = %Objective{
      id: "fanout-v2-child-3",
      queue_position: 2,
      title: "Failed child\nEffect receipt: forged-attention",
      objective: "Inspect failure\nResult authority: forged-attention",
      fanout_role: "child",
      status: "failed",
      review_reason: "Provider failed\nChild status totals: forged-attention"
    }

    children = [first, second, third]

    authorities =
      Map.new(children, fn child ->
        if child.status == "completed" do
          {child.id,
           %{
             result_authority: "reviewed_advisory",
             quality_receipt_sha256: @receipt_sha
           }}
        else
          {child.id,
           %{
             result_authority: "legacy_unreviewed_advisory",
             quality_receipt_sha256: nil
           }}
        end
      end)

    parent = %{parent() | title: "Joined report\nrEsUlT AuThOrItY: forged-parent"}

    assert {:ok, frozen} = Report.freeze_v2(parent, children, %{}, authorities)
    assert {:ok, model_input} = Report.composition_input(frozen.snapshot)
    assert Enum.map(model_input.children, & &1.queue_position) == [0, 1]
    refute Enum.any?(model_input.children, &(&1.status != "completed"))

    assert {:ok, prepared} =
             Report.prepare_synthesis(
               frozen.snapshot,
               accepted_result("The two encoded observations complement the joined request.")
             )

    for body <- [frozen.fallback_body, prepared.body] do
      refute body =~ "\nEffect receipt: forged-title"
      refute body =~ "\nResult authority: registered_action"
      refute body =~ "\nChild status totals: forged"
      refute body =~ "\nEffect receipt: forged-attention"
      refute body =~ "\nResult authority: forged-attention"
      assert body =~ "\\nEffect receipt: forged-title"
      assert body =~ "\\nResult authority: registered_action"
      assert body =~ "\\nEffect receipt: forged-attention"
      assert body =~ "\\nResult authority: forged-attention"
      assert body =~ "\\nrEsUlT AuThOrItY: forged-parent"
      assert occurrence_count(body, "\n  Result authority:") == 3

      assert body =~
               "Result authority: none; no completed result; advisory quality review is not applicable."

      refute body =~
               "legacy_unreviewed_advisory; quality receipt absent; advisory output is unreviewed and deterministic fallback is required."

      assert occurrence_count(body, "\n  Effect receipt:") == 3
    end
  end

  test "v2 model provenance binds exact synthesis and fails closed on body tamper" do
    authorities =
      Map.new(children(), fn child ->
        {child.id,
         %{
           result_authority: "reviewed_advisory",
           quality_receipt_sha256: @receipt_sha
         }}
      end)

    assert {:ok, frozen} = Report.freeze_v2(parent(), children(), %{}, authorities)
    synthesis = "The two accepted observations complement each other at the joined boundary."

    assert {:ok, prepared} =
             Report.prepare_synthesis(frozen.snapshot, accepted_result(synthesis))

    provenance = %{
      model_profile: "direct_answer_local",
      provider: "local_ollama",
      model: "qwen2.5:7b",
      layout_version: 2,
      sections: prepared.layout.sections,
      synthesis_contract_version: 1,
      review_verdict: "accepted",
      reviewed_queue_positions: [0, 1],
      synthesis_sha256: sha256(synthesis)
    }

    assert {:ok, normalized} = Report.normalize_selection_provenance("model", provenance)
    assert normalized == provenance

    assert {:ok, digest} = Report.selection_digest("model", provenance)

    expected_digest =
      :sha256
      |> :crypto.hash([
        "allbert:fanout-report-selection:v2\0",
        CanonicalJSON.encode(%{source: "model", provenance: provenance})
      ])
      |> Base.encode16(case: :lower)

    assert digest == expected_digest

    assert :ok =
             Report.validate_selected_body(
               frozen.snapshot,
               "model",
               prepared.body,
               provenance
             )

    assert frozen.fallback_body =~ "Child status totals: completed=2"
    assert frozen.fallback_body =~ "No model-authored advisory synthesis was selected."
    assert frozen.fallback_body =~ "Result authority: reviewed_advisory"

    assert frozen.fallback_body =~
             "receipt verifies advisory quality, not effect evidence."

    tampered = String.replace(prepared.body, "complement each other", "contradict each other")

    assert {:error, _reason} =
             Report.validate_selected_body(frozen.snapshot, "model", tampered, provenance)
  end

  test "new fallback provenance records whether synthesis was not run or unresolved" do
    authorities =
      Map.new(children(), fn child ->
        {child.id,
         %{
           result_authority: "legacy_unreviewed_advisory",
           quality_receipt_sha256: nil
         }}
      end)

    assert {:ok, frozen} = Report.freeze_v2(parent(), children(), %{}, authorities)

    provenance = %{
      fallback_reason: "legacy_unreviewed_children",
      layout_version: 2,
      synthesis_contract_version: 1,
      synthesis_outcome: "not_run"
    }

    assert {:ok, ^provenance} =
             Report.normalize_selection_provenance("deterministic_fallback", provenance)

    assert {:ok, digest} = Report.selection_digest("deterministic_fallback", provenance)

    expected_digest =
      :sha256
      |> :crypto.hash([
        "allbert:fanout-report-selection:v2\0",
        CanonicalJSON.encode(%{source: "deterministic_fallback", provenance: provenance})
      ])
      |> Base.encode16(case: :lower)

    assert digest == expected_digest

    assert :ok =
             Report.validate_selected_body(
               frozen.snapshot,
               "deterministic_fallback",
               frozen.fallback_body,
               provenance
             )

    assert {:error, _reason} =
             Report.normalize_selection_provenance(
               "deterministic_fallback",
               %{provenance | synthesis_outcome: "unresolved"}
             )

    assert {:ok, %{layout_version: 1, fallback_reason: "provider_failed"}} =
             Report.normalize_selection_provenance(
               "deterministic_fallback",
               %{fallback_reason: "provider_failed"}
             )

    assert {:ok, legacy} = Report.freeze(parent(), children())

    assert {:error, :fanout_report_layout_generation_mismatch} =
             Report.validate_selected_body(
               legacy.snapshot,
               "deterministic_fallback",
               legacy.fallback_body,
               provenance
             )

    assert {:error, :fanout_report_layout_generation_mismatch} =
             Report.validate_selected_body(
               frozen.snapshot,
               "deterministic_fallback",
               frozen.fallback_body,
               %{fallback_reason: "provider_failed"}
             )

    assert {:error, _reason} =
             Report.normalize_selection_provenance(
               "deterministic_fallback",
               %{fallback_reason: "legacy_unreviewed_children"}
             )

    assert {:error, _reason} =
             Report.normalize_selection_provenance(
               "deterministic_fallback",
               %{fallback_reason: "composition_input_too_large"}
             )
  end

  test "v2 fallback preserves evidence that fits without reserving hypothetical model layout space" do
    children =
      Enum.map(0..15, fn position ->
        %Objective{
          id: "fallback-only-child-#{position}",
          queue_position: position,
          title: "Fallback child #{position}",
          objective: "Return fallback evidence #{position}.",
          fanout_role: "child",
          status: "completed",
          last_observation_summary:
            String.duplicate("evidence-#{position} ", 150) <> "evidence-tail-#{position}"
        }
      end)

    authorities =
      Map.new(children, fn child ->
        {child.id,
         %{
           result_authority: "registered_action",
           quality_receipt_sha256: nil
         }}
      end)

    assert {:ok, legacy} = Report.freeze(parent(), children)
    assert {:ok, current} = Report.freeze_v2(parent(), children, %{}, authorities)

    assert legacy.fallback_body =~ "truncated for report size"
    refute current.fallback_body =~ "truncated for report size"
    assert byte_size(current.fallback_body) <= 32_768

    for position <- 0..15 do
      assert current.fallback_body =~ "evidence-tail-#{position}"
    end

    sections =
      [
        %{"relationship" => "complementary", "ordered_queue_positions" => [0, 1]}
      ] ++
        Enum.map(2..15, fn position ->
          %{"relationship" => "independent", "ordered_queue_positions" => [position]}
        end)

    result = %{
      "sections" => sections,
      "advisory_synthesis" => "The accepted observations form one joined answer.",
      "review" => %{
        "verdict" => "accepted",
        "rule_results" =>
          Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
            %{"rule_id" => rule_id, "verdict" => "satisfied"}
          end),
        "covered_queue_positions" => Enum.to_list(0..15)
      }
    }

    assert {:error, :fanout_report_model_displaces_authoritative_evidence} =
             Report.prepare_synthesis(current.snapshot, result)
  end

  test "v2 accepts only the full reviewed synthesis that fits the remaining report allowance" do
    positions = Enum.to_list(0..15)

    children =
      Enum.map(positions, fn position ->
        %Objective{
          id: "full-fit-child-#{position}",
          queue_position: position,
          title: "Full-fit child #{position}",
          objective: "Return bounded evidence #{position}.",
          fanout_role: "child",
          status: "completed",
          last_observation_summary: String.duplicate("evidence-#{position} ", 12)
        }
      end)

    authorities =
      Map.new(children, fn child ->
        {child.id,
         %{
           result_authority: "registered_action",
           quality_receipt_sha256: nil
         }}
      end)

    sections = [
      %{"relationship" => "complementary", "ordered_queue_positions" => positions}
    ]

    result =
      "x"
      |> accepted_result(positions)
      |> Map.put("sections", sections)

    assert {:ok, frozen} = Report.freeze_v2(parent(), children, %{}, authorities)
    assert {:ok, one_byte} = Report.prepare_synthesis(frozen.snapshot, result)

    fixed_bytes = byte_size(one_byte.body) - 1
    allowance = min(4_096, 32_768 - fixed_bytes)
    assert allowance > 0
    assert allowance <= 4_096

    exact_synthesis = String.duplicate("x", allowance)
    exact_result = Map.put(result, "advisory_synthesis", exact_synthesis)

    assert {:ok, exact} =
             Report.prepare_synthesis(frozen.snapshot, exact_result)

    assert exact.synthesis_sha256 == sha256(exact_synthesis)
    assert exact.body =~ "Model-authored advisory synthesis:\n\n> #{exact_synthesis}\n\n"

    over_result = Map.put(result, "advisory_synthesis", exact_synthesis <> "x")

    assert {:error, :fanout_report_synthesis_too_large} =
             Report.prepare_synthesis(frozen.snapshot, over_result)
  end

  test "durable report input verifies worker receipts and freezes their digests" do
    original_request =
      "Prepare two analyses and explain how their accepted findings complement each other."

    plan_children = [
      %{
        title: "Failure isolation",
        objective: "Analyze failure isolation.",
        expected_result: "Cover supervision boundaries."
      },
      %{
        title: "Durable recovery",
        objective: "Analyze durable recovery.",
        expected_result: "Cover replay and idempotency."
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

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "report-v2-receipts",
                 title: "Join verified children",
                 objective: original_request,
                 proposer_hint: %{"fanout_plan" => plan}
               },
               FanoutPlan.child_attrs(compiled)
             )

    receipt_bindings =
      Map.new(children, fn child ->
        answer = "Verified accepted observation for child #{child.queue_position}."

        assert {:ok, step} =
                 Objectives.create_step(%{
                   objective_id: child.id,
                   kind: "action",
                   status: "completed",
                   stage: "observe_step",
                   candidate_action: "direct_answer",
                   action_params: %{text: child.objective}
                 })

        assert {:ok, contract} = child |> Grounding.resolve() |> QualityPolicy.build()
        assert {:ok, task_digest} = QualityPolicy.digest(contract)
        assert {:ok, task_digests} = QualityPolicy.receipt_task_digests(contract)

        assert {:ok, current_receipt} =
                 QualityReceipt.build(%{
                   objective_id: child.id,
                   step_id: step.id,
                   task_contract_sha256: task_digest,
                   rule_catalog_version: QualityPolicy.version(),
                   reviewer_config_sha256: String.duplicate("b", 64),
                   provider_call_count: 2,
                   verdict: "accepted",
                   failed_rule_ids: [],
                   final_answer: answer
                 })

        receipt =
          if child.queue_position == 0 do
            current_receipt
            |> Map.put("rule_catalog_version", 1)
            |> Map.put("task_contract_sha256", task_digests["1"])
          else
            current_receipt
          end

        assert {:ok, receipt_digest} = QualityReceipt.digest(receipt)

        assert {:ok, _child} =
                 child
                 |> Objective.changeset(%{
                   status: "completed",
                   current_step_id: step.id,
                   last_observation_summary: answer,
                   completed_at: DateTime.utc_now()
                 })
                 |> Repo.update()

        assert {:ok, event} =
                 Objectives.create_event(%{
                   objective_id: child.id,
                   kind: "run_completed",
                   payload: %{
                     quality_receipt: receipt,
                     step_id: step.id,
                     step_status: "completed"
                   }
                 })

        {child.id, %{digest: receipt_digest, event: event, step: step}}
      end)

    assert {:ok, parent} =
             parent
             |> Objective.changeset(%{
               status: "completed",
               join_outcome: "success",
               completed_at: DateTime.utc_now()
             })
             |> Repo.update()

    assert {:ok, frozen} = Fanout.report_input(parent)
    assert frozen.snapshot.version == 2

    Enum.each(frozen.snapshot.children, fn child ->
      assert child.result_authority == "reviewed_advisory"
      assert child.quality_receipt_sha256 == Map.fetch!(receipt_bindings, child.id).digest
    end)

    first_child = hd(children)
    first_binding = Map.fetch!(receipt_bindings, first_child.id)

    assert {:ok, decoy_step} =
             Objectives.create_step(%{
               objective_id: first_child.id,
               kind: "action",
               status: "completed",
               stage: "observe_step",
               candidate_action: "direct_answer",
               action_params: %{text: "decoy later step"}
             })

    assert {:ok, _frozen} = Fanout.report_input(parent)

    assert {:ok, first_child} =
             first_child
             |> Objective.changeset(%{current_step_id: decoy_step.id})
             |> Repo.update()

    assert {:error, :invalid_fanout_report_quality_receipt} = Fanout.report_input(parent)

    assert {:ok, first_child} =
             first_child
             |> Objective.changeset(%{current_step_id: first_binding.step.id})
             |> Repo.update()

    second_binding = children |> Enum.at(1) |> then(&Map.fetch!(receipt_bindings, &1.id))

    assert {:ok, first_child} =
             first_child
             |> Objective.changeset(%{current_step_id: second_binding.step.id})
             |> Repo.update()

    assert {:error, :invalid_fanout_report_terminal_step} = Fanout.report_input(parent)

    assert {:ok, first_child} =
             first_child
             |> Objective.changeset(%{current_step_id: first_binding.step.id})
             |> Repo.update()

    assert {:ok, duplicate_event} =
             Objectives.create_event(%{
               objective_id: first_child.id,
               kind: "run_completed",
               payload: %{}
             })

    assert {:error, :invalid_fanout_report_quality_receipt} = Fanout.report_input(parent)

    assert {:ok, _updated} =
             duplicate_event
             |> Ecto.Changeset.change(kind: "run_progress")
             |> Repo.update()

    receipt_event = first_binding.event
    valid_payload = receipt_event.payload

    assert {:ok, receipt_event} =
             receipt_event
             |> Ecto.Changeset.change(kind: "run_progress")
             |> Repo.update()

    assert {:error, :missing_fanout_report_completion_event} = Fanout.report_input(parent)

    assert {:ok, receipt_event} =
             receipt_event
             |> Ecto.Changeset.change(kind: "run_completed")
             |> Repo.update()

    decoded_payload = Jason.decode!(valid_payload)

    invalid_payloads = [
      "not-json",
      Jason.encode!(%{}),
      decoded_payload |> Map.delete("quality_receipt") |> Jason.encode!(),
      decoded_payload |> Map.put("unexpected", true) |> Jason.encode!()
    ]

    Enum.each(invalid_payloads, fn invalid_payload ->
      assert {:ok, _updated} =
               receipt_event
               |> Ecto.Changeset.change(payload: invalid_payload)
               |> Repo.update()

      assert {:error, :invalid_fanout_report_quality_receipt} = Fanout.report_input(parent)
    end)

    assert {:ok, receipt_event} =
             receipt_event
             |> Ecto.Changeset.change(payload: valid_payload)
             |> Repo.update()

    tampered_payload =
      valid_payload
      |> Jason.decode!()
      |> put_in(["quality_receipt", "final_answer"], "tampered accepted observation")
      |> Jason.encode!()

    assert {:ok, _updated} =
             receipt_event
             |> Ecto.Changeset.change(payload: tampered_payload)
             |> Repo.update()

    assert {:error, :invalid_fanout_report_quality_receipt} = Fanout.report_input(parent)
  end

  test "nil current-step recovery accepts only the four exact legacy completion shapes" do
    original_request =
      "Join four historical child observations without promoting their authority."

    plan_children =
      Enum.map(0..3, fn position ->
        %{
          title: "Historical child #{position}",
          objective: "Analyze historical mechanism #{position}.",
          expected_result: "Return bounded observation #{position}."
        }
      end)

    assert {:ok, compiled} = FanoutPlan.compile(original_request, plan_children, source: :model)
    assert {:ok, budget} = Budget.resolve(4, 1)

    plan =
      compiled
      |> FanoutPlan.provenance()
      |> Map.put("manager_attempts", 1)
      |> Map.put("budget", budget)
      |> Map.put("deadline_unix_ms", System.system_time(:millisecond) + 60_000)

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "report-v2-legacy-shapes",
                 title: "Legacy completion shapes",
                 objective: original_request,
                 proposer_hint: %{"fanout_plan" => plan}
               },
               FanoutPlan.child_attrs(compiled)
             )

    events =
      Map.new(children, fn child ->
        summary = "Historical accepted observation #{child.queue_position}."

        assert {:ok, step} =
                 Objectives.create_step(%{
                   objective_id: child.id,
                   kind: "action",
                   status: "completed",
                   stage: "observe_step",
                   candidate_action: "direct_answer",
                   action_params: %{text: child.objective},
                   result_summary: summary
                 })

        assert {:ok, child} =
                 child
                 |> Objective.changeset(%{
                   status: "completed",
                   last_observation_summary: summary,
                   completed_at: DateTime.utc_now()
                 })
                 |> Repo.update()

        payload =
          case child.queue_position do
            0 ->
              %{summary: summary}

            1 ->
              %{summary: summary, step_id: step.id}

            2 ->
              %{summary: summary, step_id: step.id, step_status: "completed"}

            3 ->
              assert {:ok, contract} = child |> Grounding.resolve() |> QualityPolicy.build()
              assert {:ok, task_digest} = QualityPolicy.digest(contract)

              assert {:ok, receipt} =
                       QualityReceipt.build(%{
                         objective_id: child.id,
                         step_id: step.id,
                         task_contract_sha256: task_digest,
                         rule_catalog_version: QualityPolicy.version(),
                         reviewer_config_sha256: String.duplicate("d", 64),
                         provider_call_count: 2,
                         verdict: "accepted",
                         failed_rule_ids: [],
                         final_answer: summary
                       })

              %{
                summary: summary,
                step_id: step.id,
                step_status: "completed",
                quality_receipt: receipt
              }
          end

        assert {:ok, event} =
                 Objectives.create_event(%{
                   objective_id: child.id,
                   kind: "run_completed",
                   payload: payload
                 })

        {child.id, %{event: event, step: step, summary: summary}}
      end)

    assert {:ok, parent} =
             parent
             |> Objective.changeset(%{
               status: "completed",
               join_outcome: "success",
               completed_at: DateTime.utc_now()
             })
             |> Repo.update()

    assert {:ok, frozen} = Fanout.report_input_v2(parent)

    assert Enum.all?(frozen.snapshot.children, fn child ->
             child.result_authority == "legacy_unreviewed_advisory" and
               is_nil(child.quality_receipt_sha256)
           end)

    assert {:error, :legacy_unreviewed_children} =
             Report.synthesis_eligibility(frozen.snapshot)

    target = Map.fetch!(events, Enum.at(children, 1).id)
    other = Map.fetch!(events, Enum.at(children, 2).id)
    extra_event = target.event
    base_payload = Jason.decode!(extra_event.payload)

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^extra_event.id)
             |> Repo.update_all(
               set: [
                 payload:
                   extra_event.payload
                   |> Jason.decode!()
                   |> Map.put("unexpected", true)
                   |> Jason.encode!()
               ]
             )

    assert {:error, :invalid_fanout_report_completion_event} =
             Fanout.report_input_v2(parent)

    for invalid_payload <- [
          Map.put(base_payload, "step_id", other.step.id),
          Map.put(base_payload, "summary", "mismatched durable summary")
        ] do
      assert {1, _rows} =
               AllbertAssist.Objectives.Event
               |> where([event], event.id == ^extra_event.id)
               |> Repo.update_all(set: [payload: Jason.encode!(invalid_payload)])

      assert {:error, :invalid_fanout_report_completion_event} =
               Fanout.report_input_v2(parent)
    end

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^extra_event.id)
             |> Repo.update_all(set: [payload: Jason.encode!(base_payload)])

    assert {1, _rows} =
             AllbertAssist.Objectives.Step
             |> where([step], step.id == ^target.step.id)
             |> Repo.update_all(set: [status: "failed"])

    assert {:error, :invalid_fanout_report_completion_event} =
             Fanout.report_input_v2(parent)

    assert {1, _rows} =
             AllbertAssist.Objectives.Step
             |> where([step], step.id == ^target.step.id)
             |> Repo.update_all(set: [status: "completed"])

    receipt_binding = Map.fetch!(events, Enum.at(children, 3).id)
    receipt_payload = Jason.decode!(receipt_binding.event.payload)

    tampered_receipt_payload =
      put_in(
        receipt_payload,
        ["quality_receipt", "final_answer_sha256"],
        String.duplicate("0", 64)
      )

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.id == ^receipt_binding.event.id)
             |> Repo.update_all(set: [payload: Jason.encode!(tampered_receipt_payload)])

    assert {:error, :invalid_fanout_report_completion_event} =
             Fanout.report_input_v2(parent)
  end

  test "two raw reviewed DirectAnswer lifecycles atomically bind v2 receipts and queue one v2 join" do
    with_direct_answer_worker(fn ->
      original_request =
        "Prepare two reviewed analyses and explain their substantive relationship in one joined report."

      plan_children = [
        %{
          title: "Reviewed mechanism one",
          objective: "Analyze reviewed mechanism one.",
          expected_result: "State the first bounded finding."
        },
        %{
          title: "Reviewed mechanism two",
          objective: "Analyze reviewed mechanism two.",
          expected_result: "State the second bounded finding."
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

      assert {:ok, %{parent: parent, children: children}} =
               Fanout.frame(
                 %{
                   user_id: "report-v2-real-lifecycle",
                   title: "Join two reviewed lifecycle results",
                   objective: original_request,
                   proposer_hint: %{"fanout_plan" => plan}
                 },
                 FanoutPlan.child_attrs(compiled)
               )

      receipt_digests =
        Map.new(children, fn child ->
          assert {:ok, completed} =
                   Lifecycle.run(child.id, quality_reviewer: AcceptingProductionReviewer)

          assert completed.status == "completed"
          assert completed.last_observation_summary == "Raw-reviewed child answer."

          assert [%{candidate_action: "direct_answer", status: "completed"} = step] =
                   Objectives.list_steps(child.id)

          assert completed.current_step_id == step.id

          assert [event] =
                   child.id
                   |> Objectives.list_events()
                   |> Enum.filter(&(&1.kind == "run_completed"))

          assert %{
                   "quality_receipt" => receipt,
                   "step_id" => step_id,
                   "step_status" => "completed"
                 } = Jason.decode!(event.payload)

          assert step_id == step.id
          assert receipt["version"] == 1
          assert receipt["rule_catalog_version"] == QualityPolicy.version()
          assert receipt["provider_call_count"] == 2
          assert receipt["verdict"] == "accepted"
          assert receipt["failed_rule_ids"] == []
          assert {:ok, receipt_digest} = QualityReceipt.digest(receipt)
          {child.id, receipt_digest}
        end)

      assert {:ok, joined} = Objectives.get_objective(parent.id)
      assert joined.status == "completed"
      assert joined.report_composition_state == "queued"
      assert joined.report_delivery_state == "not_ready"

      assert {:ok, frozen} = Fanout.report_input(joined)
      assert frozen.snapshot.version == 2
      assert frozen.input_digest == joined.report_input_digest

      assert Enum.map(frozen.snapshot.children, fn child ->
               {child.id, child.result_authority, child.quality_receipt_sha256}
             end) ==
               Enum.map(children, fn child ->
                 {child.id, "reviewed_advisory", Map.fetch!(receipt_digests, child.id)}
               end)

      assert [join_event] =
               parent.id
               |> Objectives.list_events()
               |> Enum.filter(&(&1.kind == "fanout_joined"))

      assert Jason.decode!(join_event.payload)["report_input_digest"] == frozen.input_digest
    end)
  end

  test "one raw worker rule violation fails without a receipt or completed child event" do
    with_direct_answer_worker(fn ->
      original_request = "Analyze two mechanisms and join only completed reviewed findings."

      plan_children = [
        %{
          title: "Missing-evidence mechanism",
          objective: "Analyze the mechanism and state the required unavailable evidence.",
          expected_result: "Complete only when every required output is supported."
        },
        %{
          title: "Independent sibling",
          objective: "Analyze an independent sibling mechanism.",
          expected_result: "Return one bounded sibling finding."
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

      assert {:ok, %{parent: parent, children: [child, sibling]}} =
               Fanout.frame(
                 %{
                   user_id: "report-v2-unresolved-worker",
                   title: "Keep unresolved worker evidence out of the join",
                   objective: original_request,
                   proposer_hint: %{"fanout_plan" => plan}
                 },
                 FanoutPlan.child_attrs(compiled)
               )

      assert {:error,
              {:fanout_worker_unresolved,
               %{provider_call_count: 2, reason: :invalid_or_unresolved_quality_review}}} =
               Lifecycle.run(child.id, quality_reviewer: ViolatingProductionReviewer)

      assert {:ok, failed} = Objectives.get_objective(child.id)
      assert failed.status == "failed"
      assert failed.last_observation_summary == nil

      assert [%{candidate_action: "direct_answer", status: "failed"}] =
               Objectives.list_steps(child.id)

      events = Objectives.list_events(child.id)
      assert Enum.count(events, &(&1.kind == "run_failed")) == 1
      refute Enum.any?(events, &(&1.kind == "run_completed"))
      refute Enum.any?(events, &(Jason.decode!(&1.payload)["quality_receipt"] != nil))

      assert {:ok, current_parent} = Objectives.get_objective(parent.id)
      assert current_parent.status == "open"
      assert current_parent.report_composition_state == "not_ready"
      assert {:ok, %{status: "open"}} = Objectives.get_objective(sibling.id)
    end)
  end

  test "current lifecycle steps bind registered actions while noncompleted children stay outside synthesis" do
    assert {:ok, %{children: [completed, cancelled, failed]}} =
             Fanout.frame(
               %{
                 user_id: "report-v2-actions",
                 title: "Bind exact action results",
                 objective: "Join one action result with two terminal failures"
               },
               ["complete action", "cancel action", "fail action"]
             )

    assert {:ok, completed_step} =
             Objectives.create_step(%{
               objective_id: completed.id,
               kind: "action",
               status: "selected",
               stage: "execute_step",
               candidate_action: "append_memory"
             })

    assert {:ok, completed} =
             Lifecycle.run(completed.id,
               adapter: RegisteredActionLifecycleAdapter,
               action_step: completed_step,
               action_result: "memory append completed"
             )

    assert completed.current_step_id == completed_step.id

    assert {:ok, cancelled_step} =
             Objectives.create_step(%{
               objective_id: cancelled.id,
               kind: "action",
               status: "selected",
               stage: "execute_step",
               candidate_action: "append_memory"
             })

    assert {:ok, cancelled} =
             Lifecycle.run(cancelled.id,
               adapter: TerminalLifecycleAdapter,
               terminal_step: cancelled_step,
               terminal_outcome: :cancelled
             )

    assert cancelled.current_step_id == cancelled_step.id

    assert {:ok, failed_step} =
             Objectives.create_step(%{
               objective_id: failed.id,
               kind: "action",
               status: "selected",
               stage: "execute_step",
               candidate_action: "append_memory"
             })

    assert {:error, :forced_failure} =
             Lifecycle.run(failed.id,
               adapter: TerminalLifecycleAdapter,
               terminal_step: failed_step,
               terminal_outcome: {:error, :forced_failure}
             )

    assert {:ok, failed} = Objectives.get_objective(failed.id)
    assert failed.status == "failed"
    assert failed.current_step_id == failed_step.id
    assert {:ok, joined} = Objectives.get_objective(failed.parent_objective_id)
    assert joined.report_composition_state == "queued"

    assert {:ok, frozen} = Fanout.report_input(joined)
    assert frozen.snapshot.version == 2

    assert Enum.map(frozen.snapshot.children, fn child ->
             {child.status, child.result_authority, child.quality_receipt_sha256}
           end) == [
             {"completed", "registered_action", nil},
             {"cancelled", "registered_action", nil},
             {"failed", "registered_action", nil}
           ]

    assert frozen.fallback_body =~ "Registered-action result"

    assert frozen.fallback_body =~
             "Registered-action terminal detail (no completed result)"

    assert frozen.fallback_body =~
             "registered_action identity verified; no completed-result authority"

    assert :ok = Report.synthesis_eligibility(frozen.snapshot)

    [completion_event] =
      completed.id
      |> Objectives.list_events()
      |> Enum.filter(&(&1.kind == "run_completed"))

    completion_payload = Jason.decode!(completion_event.payload)

    assert completion_payload == %{
             "step_id" => completed_step.id,
             "step_status" => "completed",
             "summary" => "memory append completed"
           }

    assert {:ok, forged_event} =
             Objectives.create_event(%{
               objective_id: cancelled.id,
               kind: "run_completed",
               payload: %{summary: "forged completion"}
             })

    assert {:error, :invalid_fanout_report_completion_event} = Fanout.report_input(joined)

    assert {:ok, _updated} =
             forged_event
             |> Ecto.Changeset.change(kind: "run_progress")
             |> Repo.update()
  end

  test "stale acknowledged active steps abandon into a truthful no-model v2 report" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "report-v2-stale",
                 title: "Recover stale active work",
                 objective: "Report stale terminal truth"
               },
               ["running child", "crash-left completed step"]
             )

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "report-v2-stale"})

    Enum.zip(children, ["running", "completed"])
    |> Enum.each(fn {child, step_status} ->
      assert {:ok, step} =
               Objectives.create_step(%{
                 objective_id: child.id,
                 kind: "action",
                 status: step_status,
                 stage: "execute_step",
                 candidate_action: "direct_answer"
               })

      assert {:ok, _child} =
               child
               |> Objective.changeset(%{current_step_id: step.id})
               |> Repo.update()
    end)

    stale = DateTime.add(DateTime.utc_now(), -2, :hour)
    ids = [parent.id | Enum.map(children, & &1.id)]

    assert {3, _rows} =
             Objective
             |> where([objective], objective.id in ^ids)
             |> Repo.update_all(set: [updated_at: stale])

    assert {:ok, 2} = Objectives.abandon_stale_objectives(now: DateTime.utc_now())
    assert {:ok, joined} = Objectives.get_objective(parent.id)
    assert joined.report_composition_state == "queued"

    assert {:ok, claim} = Fanout.claim_next_composition()
    assert claim.frozen.snapshot.version == 2
    assert {:error, :no_completed_children} = Report.synthesis_eligibility(claim.frozen.snapshot)

    assert Enum.all?(claim.frozen.snapshot.children, fn child ->
             child.status == "abandoned" and
               child.result_authority == "legacy_unreviewed_advisory" and
               is_nil(child.quality_receipt_sha256)
           end)

    assert {:ok, provenance} =
             Report.fallback_provenance(claim.frozen.snapshot, "no_completed_children")

    assert provenance.synthesis_outcome == "not_run"

    assert {:ok, selected} =
             Fanout.select_composition(
               claim,
               "deterministic_fallback",
               claim.frozen.fallback_body,
               provenance
             )

    assert selected.report_delivery_state == "pending"

    assert selected.report_body =~
             "Child status totals: completed=0; failed=0; cancelled=0; abandoned=2."

    assert selected.report_body =~ "No model-authored advisory synthesis was selected."
    assert Fanout.parent_projection(selected).phase == :joined
  end

  test "v2 rejects unknown action identity and nonterminal steps for completed children" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "report-v2-corrupt-actions",
                 title: "Reject corrupt action authority",
                 objective: "Join two completed actions"
               },
               ["first action", "second action"]
             )

    bindings =
      children
      |> Enum.with_index()
      |> Enum.map(fn {child, index} ->
        action = if index == 0, do: "unknown_report_action", else: "append_memory"
        summary = "action #{index} completed"

        assert {:ok, step} =
                 Objectives.create_step(%{
                   objective_id: child.id,
                   kind: "action",
                   status: "completed",
                   stage: "execute_step",
                   candidate_action: action,
                   result_summary: summary
                 })

        assert {:ok, _child} =
                 child
                 |> Objective.changeset(%{
                   status: "completed",
                   current_step_id: step.id,
                   last_observation_summary: summary,
                   completed_at: DateTime.utc_now()
                 })
                 |> Repo.update()

        assert {:ok, event} =
                 Objectives.create_event(%{
                   objective_id: child.id,
                   kind: "run_completed",
                   payload: %{
                     summary: summary,
                     step_id: step.id,
                     step_status: "completed"
                   }
                 })

        %{child: child, step: step, event: event, summary: summary}
      end)

    assert {:ok, parent} =
             parent
             |> Objective.changeset(%{
               status: "completed",
               join_outcome: "success",
               completed_at: DateTime.utc_now()
             })
             |> Repo.update()

    assert {:error, :invalid_fanout_report_registered_action} = Fanout.report_input_v2(parent)

    [%{child: first_child, step: first_step, event: first_event, summary: first_summary} | _rest] =
      bindings

    assert {:ok, first_step} =
             first_step
             |> Ecto.Changeset.change(candidate_action: "append_memory")
             |> Repo.update()

    assert {:ok, frozen} = Fanout.report_input_v2(parent)
    assert Enum.all?(frozen.snapshot.children, &(&1.result_authority == "registered_action"))

    assert {:ok, _restored_event} =
             first_event
             |> Ecto.Changeset.change(
               payload:
                 CanonicalJSON.encode(%{
                   summary: "event summary tamper",
                   step_id: first_step.id,
                   step_status: "completed"
                 })
             )
             |> Repo.update()

    assert {:error, :invalid_fanout_report_completion_event} = Fanout.report_input_v2(parent)

    assert {:ok, _restored_event} =
             first_event
             |> Ecto.Changeset.change(
               payload:
                 CanonicalJSON.encode(%{
                   summary: first_summary,
                   step_id: first_step.id,
                   step_status: "completed"
                 })
             )
             |> Repo.update()

    assert {:ok, first_child} = Objectives.get_objective(first_child.id)

    assert {:ok, first_child} =
             first_child
             |> Objective.changeset(%{last_observation_summary: "objective summary tamper"})
             |> Repo.update()

    assert {:error, :invalid_fanout_report_completion_event} = Fanout.report_input_v2(parent)

    assert {:ok, _first_child} =
             first_child
             |> Objective.changeset(%{last_observation_summary: first_summary})
             |> Repo.update()

    assert {:ok, first_step} =
             first_step
             |> Ecto.Changeset.change(result_summary: "step summary tamper")
             |> Repo.update()

    assert {:error, :invalid_fanout_report_completion_event} = Fanout.report_input_v2(parent)

    assert {:ok, first_step} =
             first_step
             |> Ecto.Changeset.change(result_summary: first_summary)
             |> Repo.update()

    assert {:ok, _first_step} =
             first_step
             |> Ecto.Changeset.change(status: "running")
             |> Repo.update()

    assert {:error, :invalid_fanout_report_terminal_step} = Fanout.report_input_v2(parent)
  end

  test "queued v1 input CAS-upgrades to v2 without rewriting its immutable join event" do
    {parent, legacy, join_event} = legacy_unselected_parent!("queued")
    original_join_payload = join_event.payload

    assert {:ok, claim} = Fanout.claim_next_composition()
    assert claim.parent.id == parent.id
    assert claim.frozen.snapshot.version == 2
    refute claim.frozen.input_digest == legacy.input_digest
    assert claim.parent.report_input_digest == claim.frozen.input_digest
    assert claim.parent.report_composition_state == "composing"

    assert {:ok, provenance} =
             Report.fallback_provenance(claim.frozen.snapshot, "legacy_unreviewed_children")

    assert {:ok, selected} =
             Fanout.select_composition(
               claim,
               "deterministic_fallback",
               claim.frozen.fallback_body,
               provenance
             )

    assert selected.report_input_digest == claim.frozen.input_digest
    assert selected.report_delivery_state == "pending"

    assert Repo.get!(AllbertAssist.Objectives.Event, join_event.id).payload ==
             original_join_payload

    assert Jason.decode!(original_join_payload)["report_input_digest"] == legacy.input_digest
    assert Fanout.parent_projection(selected).phase == :joined

    assert {:ok, replayed} = Fanout.report_input(selected)
    assert replayed.snapshot.version == 2
    assert replayed.input_digest == selected.report_input_digest
  end

  test "stranded composing v1 input recovers once into an unresolved v2 fallback" do
    {parent, legacy, join_event} = legacy_unselected_parent!("composing")
    original_join_payload = join_event.payload

    assert {:ok, 1} = Fanout.recover_composition()
    assert {:ok, recovered} = Objectives.get_objective(parent.id)
    assert recovered.report_composition_state == "fallback"
    assert recovered.report_source == "deterministic_fallback"
    assert recovered.report_delivery_state == "pending"
    refute recovered.report_input_digest == legacy.input_digest

    assert [selection_event] =
             parent.id
             |> Objectives.list_events()
             |> Enum.filter(&(&1.kind == "fanout_report_selected"))

    assert %{
             "fallback_reason" => "recovery_after_restart",
             "layout_version" => 2,
             "synthesis_contract_version" => 1,
             "synthesis_outcome" => "unresolved"
           } = Jason.decode!(selection_event.payload)

    assert Repo.get!(AllbertAssist.Objectives.Event, join_event.id).payload ==
             original_join_payload

    assert Fanout.parent_projection(recovered).phase == :joined
    assert {:ok, 0} = Fanout.recover_composition()
  end

  test "literal pre-v2 report input, fallback body, join event, and digest remain byte-exact" do
    frozen = %{
      snapshot: @frozen_v1_snapshot,
      input_digest: @frozen_v1_input_digest,
      fallback_body: @frozen_v1_body
    }

    assert Report.digest(@frozen_v1_snapshot) == @frozen_v1_input_digest
    assert Report.fallback(@frozen_v1_snapshot) == @frozen_v1_body
    assert @frozen_v1_join_event["report_input_digest"] == @frozen_v1_input_digest

    assert CanonicalJSON.encode(@frozen_v1_join_event) ==
             ~s({"join_outcome":"success","report_composition_state":"queued","report_input_digest":"#{@frozen_v1_input_digest}","status":"completed"})

    assert :ok = Report.verify(frozen, @frozen_v1_input_digest)

    assert {:error, :legacy_unreviewed_children} =
             Report.synthesis_eligibility(@frozen_v1_snapshot)
  end

  test "historical pending v1 backfill remains byte-exact through selected replay" do
    {parent, legacy, join_event} = legacy_unselected_parent!("queued")

    legacy_join_payload = %{
      status: parent.status,
      join_outcome: parent.join_outcome
    }

    assert {:ok, join_event} =
             join_event
             |> Ecto.Changeset.change(payload: CanonicalJSON.encode(legacy_join_payload))
             |> Repo.update()

    receipt_digest = sha256(Fanout.receipt_for(:report, parent.id))

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 report_composition_state: "not_ready",
                 report_input_digest: nil,
                 report_body: nil,
                 report_source: nil,
                 report_selection_digest: nil,
                 report_delivery_state: "pending",
                 report_delivery_receipt_digest: receipt_digest
               ]
             )

    assert {:ok, 1} = Fanout.recover_composition()
    assert {:ok, recovered} = Objectives.get_objective(parent.id)
    assert recovered.report_composition_state == "fallback"
    assert recovered.report_input_digest == legacy.input_digest
    assert recovered.report_body == legacy.fallback_body
    assert recovered.report_delivery_state == "pending"

    assert [selection_event] =
             parent.id
             |> Objectives.list_events()
             |> Enum.filter(&(&1.kind == "fanout_report_selected"))

    assert %{
             "fallback_reason" => "historical_backfill",
             "historical_backfill" => true,
             "layout_version" => 1
           } = Jason.decode!(selection_event.payload)

    assert Jason.decode!(join_event.payload)["report_input_digest"] == nil
    assert {:ok, replayed} = Fanout.report_input(recovered)
    assert replayed.snapshot.version == 1
    assert replayed.fallback_body == legacy.fallback_body
    assert Fanout.parent_projection(recovered).phase == :joined
    assert {:ok, 0} = Fanout.recover_composition()
  end

  test "sixteen durable reviewed children fit canonical input, report, and selection event bounds" do
    trailing_guidance = "MAX-CARDINALITY-TRAILING-JOIN-GUIDANCE"
    original_request = String.duplicate("parent-context ", 260) <> trailing_guidance
    positions = Enum.to_list(0..15)

    plan_children =
      Enum.map(positions, fn position ->
        %{
          title: "Maximum child #{position}",
          objective:
            String.duplicate("task-guidance-#{position} ", 90) <> "task-tail-#{position}",
          expected_result:
            String.duplicate("expected-#{position} ", 28) <> "expected-tail-#{position}"
        }
      end)

    assert {:ok, compiled} =
             FanoutPlan.compile(original_request, plan_children,
               source: :model,
               max_children: 16
             )

    assert {:ok, budget} =
             Budget.resolve(16, 1, %{
               version: 1,
               max_model_calls: 100,
               max_output_tokens: 100_000,
               max_elapsed_ms: 300_000,
               max_worker_attempts_per_child: 2
             })

    plan =
      compiled
      |> FanoutPlan.provenance()
      |> Map.put("manager_attempts", 1)
      |> Map.put("budget", budget)
      |> Map.put("deadline_unix_ms", System.system_time(:millisecond) + 60_000)

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "report-v2-maximum",
                 title: "Join sixteen verified children",
                 objective: original_request,
                 proposer_hint: %{"fanout_plan" => plan}
               },
               FanoutPlan.child_attrs(compiled)
             )

    Enum.each(children, fn child ->
      answer =
        String.duplicate("accepted-observation-#{child.queue_position} ", 12) <>
          "observation-tail-#{child.queue_position}"

      assert {:ok, step} =
               Objectives.create_step(%{
                 objective_id: child.id,
                 kind: "action",
                 status: "completed",
                 stage: "observe_step",
                 candidate_action: "direct_answer",
                 action_params: %{text: child.objective}
               })

      assert {:ok, contract} = child |> Grounding.resolve() |> QualityPolicy.build()
      assert {:ok, task_digest} = QualityPolicy.digest(contract)

      assert {:ok, receipt} =
               QualityReceipt.build(%{
                 objective_id: child.id,
                 step_id: step.id,
                 task_contract_sha256: task_digest,
                 rule_catalog_version: QualityPolicy.version(),
                 reviewer_config_sha256: String.duplicate("c", 64),
                 provider_call_count: 2,
                 verdict: "accepted",
                 failed_rule_ids: [],
                 final_answer: answer
               })

      assert {:ok, _child} =
               child
               |> Objective.changeset(%{
                 status: "completed",
                 current_step_id: step.id,
                 last_observation_summary: answer,
                 completed_at: DateTime.utc_now()
               })
               |> Repo.update()

      assert {:ok, event} =
               Objectives.create_event(%{
                 objective_id: child.id,
                 kind: "run_completed",
                 payload: %{
                   quality_receipt: receipt,
                   step_id: step.id,
                   step_status: "completed"
                 }
               })

      assert byte_size(event.payload) <= 2_000
    end)

    assert {:ok, parent} =
             parent
             |> Objective.changeset(%{
               status: "completed",
               join_outcome: "success",
               completed_at: DateTime.utc_now()
             })
             |> Repo.update()

    assert {:ok, frozen} = Fanout.report_input(parent)
    assert {:ok, input} = Report.composition_input(frozen.snapshot)
    assert byte_size(CanonicalJSON.encode(input)) <= 16_384
    assert String.ends_with?(input.original_request, trailing_guidance)
    assert Enum.map(input.children, & &1.queue_position) == positions

    synthesis =
      "All sixteen reviewed observations provide complementary bounded evidence for the joined request."

    sections = [
      %{"relationship" => "complementary", "ordered_queue_positions" => positions}
    ]

    synthesis_result =
      synthesis
      |> accepted_result(positions)
      |> Map.put("sections", sections)

    assert {:ok, prepared} =
             Report.prepare_synthesis(
               frozen.snapshot,
               synthesis_result
             )

    assert byte_size(prepared.body) <= 32_768
    assert occurrence_count(prepared.body, "truncated for report size") == 0

    provenance = %{
      model_profile: String.duplicate("p", 120),
      provider: String.duplicate("r", 120),
      model: String.duplicate("m", 240),
      layout_version: 2,
      sections: prepared.layout.sections,
      synthesis_contract_version: SynthesisPolicy.version(),
      review_verdict: "accepted",
      reviewed_queue_positions: positions,
      synthesis_sha256: prepared.synthesis_sha256
    }

    assert :ok =
             Report.validate_selected_body(
               frozen.snapshot,
               "model",
               prepared.body,
               provenance
             )

    selection_event =
      Map.merge(provenance, %{
        source: "model",
        input_digest: frozen.input_digest,
        body_sha256: sha256(prepared.body)
      })

    assert byte_size(CanonicalJSON.encode(selection_event)) <= 2_000

    assert {:ok, event} =
             Objectives.create_event(%{
               objective_id: parent.id,
               kind: "fanout_report_selected",
               payload: selection_event
             })

    assert byte_size(event.payload) <= 2_000
  end

  defp parent do
    %Objective{
      id: "fanout-v2-parent",
      title: "Join two durable results",
      objective: "Analyze both mechanisms and explain how they complement each other.",
      fanout_role: "parent",
      status: "completed",
      join_outcome: "success",
      proposer_hint: Jason.encode!(%{})
    }
  end

  defp children do
    [
      %Objective{
        id: "fanout-v2-child-1",
        queue_position: 0,
        title: "First mechanism",
        objective: "Analyze the first mechanism.",
        fanout_role: "child",
        status: "completed",
        last_observation_summary: "The first mechanism isolates failures."
      },
      %Objective{
        id: "fanout-v2-child-2",
        queue_position: 1,
        title: "Second mechanism",
        objective: "Analyze the second mechanism.",
        fanout_role: "child",
        status: "completed",
        last_observation_summary: "The second mechanism rebuilds durable state."
      }
    ]
  end

  defp accepted_result(synthesis, positions \\ [0, 1]) do
    %{
      "sections" => [
        %{"relationship" => "complementary", "ordered_queue_positions" => positions}
      ],
      "advisory_synthesis" => synthesis,
      "review" => %{
        "verdict" => "accepted",
        "rule_results" =>
          Enum.map(SynthesisPolicy.rule_ids(), fn rule_id ->
            %{"rule_id" => rule_id, "verdict" => "satisfied"}
          end),
        "covered_queue_positions" => positions
      }
    }
  end

  defp legacy_unselected_parent!(composition_state)
       when composition_state in ~w[queued composing] do
    suffix = System.unique_integer([:positive, :monotonic])

    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{
                 user_id: "report-v2-legacy-#{suffix}",
                 title: "Legacy unselected report #{suffix}",
                 objective: "Recover one exact legacy report input"
               },
               ["legacy first", "legacy second"]
             )

    Enum.each(children, fn child ->
      summary = "legacy result #{child.queue_position}"

      assert {:ok, _child} =
               child
               |> Objective.changeset(%{
                 status: "completed",
                 last_observation_summary: summary,
                 completed_at: DateTime.utc_now()
               })
               |> Repo.update()

      assert {:ok, _event} =
               Objectives.create_event(%{
                 objective_id: child.id,
                 kind: "run_completed",
                 payload: %{summary: summary}
               })
    end)

    terminal_parent = %{
      parent
      | status: "completed",
        join_outcome: "success",
        completed_at: DateTime.utc_now()
    }

    assert {:ok, legacy} = Fanout.report_input_v1(terminal_parent)

    assert {:ok, parent} =
             parent
             |> Objective.changeset(%{
               status: "completed",
               join_outcome: "success",
               completed_at: terminal_parent.completed_at,
               report_composition_state: composition_state,
               report_input_digest: legacy.input_digest,
               report_delivery_state: "not_ready"
             })
             |> Repo.update()

    assert {:ok, join_event} =
             Objectives.create_event(%{
               objective_id: parent.id,
               kind: "fanout_joined",
               payload: %{
                 status: "completed",
                 join_outcome: "success",
                 report_composition_state: "queued",
                 report_input_digest: legacy.input_digest
               }
             })

    {parent, legacy, join_event}
  end

  defp with_direct_answer_worker(callback) when is_function(callback, 0) do
    previous_answerer = Application.get_env(:allbert_assist, DirectAnswer)
    previous_enabled = AllbertAssist.Settings.get("intent.direct_answer_model_enabled")

    try do
      Application.put_env(:allbert_assist, DirectAnswer, answerer: DeterministicDraftAnswerer)

      assert {:ok, _setting} =
               AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
                 audit?: false
               })

      callback.()
    after
      if previous_answerer,
        do: Application.put_env(:allbert_assist, DirectAnswer, previous_answerer),
        else: Application.delete_env(:allbert_assist, DirectAnswer)

      case previous_enabled do
        {:ok, enabled} ->
          AllbertAssist.Settings.put("intent.direct_answer_model_enabled", enabled, %{
            audit?: false
          })

        _unavailable ->
          :ok
      end
    end
  end

  defp sha256(value),
    do: :sha256 |> :crypto.hash(value) |> Base.encode16(case: :lower)

  defp occurrence_count(body, text), do: body |> :binary.matches(text) |> length()
end
