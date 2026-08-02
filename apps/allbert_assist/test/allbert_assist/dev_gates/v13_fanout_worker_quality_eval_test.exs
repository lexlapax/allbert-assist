defmodule AllbertAssist.DevGates.V13FanoutWorkerQualityEvalTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.DevGates.V13FanoutWorkerQualityEval
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Objectives.Fanout.ReviewRound

  @fixture Path.expand("../../fixtures/v1.3/fanout_worker_quality_eval.json", __DIR__)
  @fixture_sha256 "a482d406a5037b66e31b8d9fd91b2435b7ef7aa0985221aced5b338558ffbd83"
  @full_sha String.duplicate("a", 40)
  @profile %{
    name: "direct_answer_local",
    provider: "local_ollama",
    model: "qwen2.5:7b"
  }

  defmodule ScenarioCritic do
    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      phase = Map.fetch!(context, :fanout_review_phase)
      case_id = Map.fetch!(context, :quality_eval_case_id)
      group_id = request["group"]["id"]

      if test_pid = Map.get(context, :test_pid),
        do: send(test_pid, {:quality_eval_critic_call, case_id, phase, group_id})

      failed_rule_ids = failed_rule_ids(case_id, phase)

      assessments =
        Enum.map(request["group"]["rule_ids"], fn rule_id ->
          %{
            "rule_id" => rule_id,
            "status" => if(rule_id in failed_rule_ids, do: "violated", else: "satisfied"),
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{"group_id" => group_id, "assessments" => assessments},
         reviewer_config_sha256: sha256("#{phase}:#{group_id}:scenario-critic-v1")
       }}
    end

    defp failed_rule_ids("restart-inaccuracy-repaired", :initial),
      do: ["preserve_supplied_semantics"]

    defp failed_rule_ids("replay-guarantee-overclaim-repaired", :initial),
      do: ["uncertainty_and_guarantees"]

    defp failed_rule_ids("omitted-required-nuance-unresolved", _phase),
      do: ["completion_preconditions"]

    defp failed_rule_ids(_case_id, _phase), do: []

    defp sha256(value) do
      :sha256
      |> :crypto.hash(value)
      |> Base.encode16(case: :lower)
    end
  end

  defmodule WrongRuleSameGeometryCritic do
    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      phase = Map.fetch!(context, :fanout_review_phase)
      case_id = Map.fetch!(context, :quality_eval_case_id)
      group_id = request["group"]["id"]
      failed_rule_ids = failed_rule_ids(case_id, phase)

      assessments =
        Enum.map(request["group"]["rule_ids"], fn rule_id ->
          %{
            "rule_id" => rule_id,
            "status" => if(rule_id in failed_rule_ids, do: "violated", else: "satisfied"),
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{"group_id" => group_id, "assessments" => assessments},
         reviewer_config_sha256: sha256("#{phase}:#{group_id}:wrong-rule-v1")
       }}
    end

    defp failed_rule_ids("restart-inaccuracy-repaired", :initial),
      do: ["no_unsupplied_details"]

    defp failed_rule_ids("replay-guarantee-overclaim-repaired", :initial),
      do: ["uncertainty_and_guarantees"]

    defp failed_rule_ids("omitted-required-nuance-unresolved", :initial),
      do: ["completion_preconditions"]

    defp failed_rule_ids("omitted-required-nuance-unresolved", :final),
      do: ["uncertainty_and_guarantees"]

    defp failed_rule_ids(_case_id, _phase), do: []

    defp sha256(value) do
      :sha256
      |> :crypto.hash(value)
      |> Base.encode16(case: :lower)
    end
  end

  defmodule ScenarioAnswerer do
    def answer(_prompt, context) do
      :ok = ProviderAttempt.mark(context)
      case_id = Map.fetch!(context, :quality_eval_case_id)

      if test_pid = Map.get(context, :test_pid),
        do: send(test_pid, {:quality_eval_revision_call, case_id})

      message =
        case case_id do
          "restart-inaccuracy-repaired" ->
            "one_for_one restarts only the failed child; rest_for_one also restarts later children."

          "replay-guarantee-overclaim-repaired" ->
            "Replay may redeliver events, while idempotent handling makes repeated application safe."

          "omitted-required-nuance-unresolved" ->
            "The owner is Team Blue, but the supplied record has no rollback threshold."
        end

      {:ok, %{message: message, diagnostic: %{status: :used}}}
    end
  end

  defmodule AcceptEverythingCritic do
    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      group_id = request["group"]["id"]

      assessments =
        Enum.map(request["group"]["rule_ids"], fn rule_id ->
          %{
            "rule_id" => rule_id,
            "status" => "satisfied",
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{"group_id" => group_id, "assessments" => assessments},
         reviewer_config_sha256: String.duplicate("b", 64)
       }}
    end
  end

  defmodule MalformedCritic do
    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)

      {:ok,
       %{
         assessment: %{
           "group_id" => request["group"]["id"],
           "assessments" => []
         },
         reviewer_config_sha256: String.duplicate("c", 64)
       }}
    end
  end

  defmodule ForgedEvidenceCritic do
    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)
      group_id = request["group"]["id"]

      assessments =
        Enum.map(request["group"]["rule_ids"], fn rule_id ->
          %{
            "rule_id" => rule_id,
            "status" => "satisfied",
            "source_handles" => ["task_contract", "candidate"]
          }
        end)

      {:ok,
       %{
         assessment: %{
           "group_id" => group_id,
           "assessments" => assessments,
           "assessment_sha256" => String.duplicate("f", 64)
         },
         reviewer_config_sha256: String.duplicate("e", 64)
       }}
    end
  end

  defmodule SlowCritic do
    def assess(request, context) do
      :ok = ReviewRound.note_provider_attempt(context)

      if test_pid = Map.get(context, :test_pid),
        do: send(test_pid, {:quality_eval_slow_critic, context.quality_eval_case_id})

      Process.sleep(1_000)

      {:ok,
       %{
         assessment: %{"group_id" => request["group"]["id"], "assessments" => []},
         reviewer_config_sha256: String.duplicate("d", 64)
       }}
    end
  end

  defmodule RevisionPreflightFailure do
    def answer(_prompt, context) do
      if test_pid = Map.get(context, :test_pid),
        do:
          send(test_pid, {:quality_eval_revision_preflight_failed, context.quality_eval_case_id})

      {:error, :model_spec_unavailable}
    end
  end

  setup do
    previous = Application.get_env(:allbert_assist, DirectAnswer)
    Application.put_env(:allbert_assist, DirectAnswer, answerer: ScenarioAnswerer)

    assert {:ok, _setting} =
             AllbertAssist.Settings.put("intent.direct_answer_model_enabled", true, %{
               audit?: false
             })

    on_exit(fn ->
      if previous,
        do: Application.put_env(:allbert_assist, DirectAnswer, previous),
        else: Application.delete_env(:allbert_assist, DirectAnswer)

      AllbertAssist.Settings.put("intent.direct_answer_model_enabled", false, %{audit?: false})
    end)

    :ok
  end

  test "frozen drafts traverse the phase-separated Worker FSM with exact 3/6 call receipts" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result =
      run(fixture,
        critic: ScenarioCritic,
        runner_context: %{test_pid: self()},
        store: store
      )

    assert result.status == "passed"
    assert result.failed_rows == []

    assert Enum.map(result.rows, &{&1.id, &1.verdict, &1.provider_call_count}) == [
             {"restart-inaccuracy-repaired", "accepted", 6},
             {"replay-guarantee-overclaim-repaired", "accepted", 6},
             {"omitted-required-nuance-unresolved", "unresolved", 6},
             {"accurate-paraphrase-accepted", "accepted", 3},
             {"unrelated-domain-accepted", "accepted", 3}
           ]

    assert Enum.map(result.rows, &{&1.initial_critic_group_count, &1.final_critic_group_count}) ==
             [
               {2, 2},
               {2, 2},
               {2, 2},
               {2, 0},
               {2, 0}
             ]

    assert Enum.map(result.rows, & &1.receipt_version) == [2, 2, nil, 2, 2]
    assert Enum.map(result.rows, & &1.configured_critic_invocation_count) == [4, 4, 4, 2, 2]
    assert Enum.map(result.rows, & &1.configured_revision_invocation_count) == [1, 1, 1, 0, 0]

    assert Enum.map(result.rows, &{&1.initial_failed_rule_count, &1.final_failed_rule_count}) == [
             {1, 0},
             {1, 0},
             {1, 1},
             {0, nil},
             {0, nil}
           ]

    refute Enum.any?(result.rows, &Map.has_key?(&1, :initial_failed_rule_ids))
    refute Enum.any?(result.rows, &Map.has_key?(&1, :final_failed_rule_ids))

    assert Enum.map(result.rows, &{&1.id, &1.failed_rule_count}) == [
             {"restart-inaccuracy-repaired", 0},
             {"replay-guarantee-overclaim-repaired", 0},
             {"omitted-required-nuance-unresolved", 1},
             {"accurate-paraphrase-accepted", 0},
             {"unrelated-domain-accepted", 0}
           ]

    assert Enum.all?(result.rows, & &1.rule_evidence_closed)
    assert Enum.all?(result.rows, &(&1.failure_stage == "none"))
    assert Enum.all?(result.rows, &(&1.failure_reason == "none"))

    assert result.stats.fixture_sha256 == @fixture_sha256
    assert result.stats.protocol_provider_call_count == 24
    assert result.stats.provider_call_count_closed == true
    assert result.stats.configured_critic_invocation_count == 16
    assert result.stats.configured_revision_invocation_count == 3
    assert result.stats.phase_evidence_closed == true
    assert result.stats.rule_evidence_closed == true
    assert result.stats.required_change_rows_changed == 2

    assert result.stats.worker_quality_receipt_version_by_row == %{
             "restart-inaccuracy-repaired" => 2,
             "replay-guarantee-overclaim-repaired" => 2,
             "omitted-required-nuance-unresolved" => nil,
             "accurate-paraphrase-accepted" => 2,
             "unrelated-domain-accepted" => 2
           }

    assert result.stats.worker_quality_verdict_by_row == %{
             "restart-inaccuracy-repaired" => "accepted",
             "replay-guarantee-overclaim-repaired" => "accepted",
             "omitted-required-nuance-unresolved" => "unresolved",
             "accurate-paraphrase-accepted" => "accepted",
             "unrelated-domain-accepted" => "accepted"
           }

    assert result.stats.worker_quality_provider_call_count_by_row == %{
             "restart-inaccuracy-repaired" => 6,
             "replay-guarantee-overclaim-repaired" => 6,
             "omitted-required-nuance-unresolved" => 6,
             "accurate-paraphrase-accepted" => 3,
             "unrelated-domain-accepted" => 3
           }

    assert result.stats.worker_quality_revision_used_by_row == %{
             "restart-inaccuracy-repaired" => true,
             "replay-guarantee-overclaim-repaired" => true,
             "omitted-required-nuance-unresolved" => true,
             "accurate-paraphrase-accepted" => false,
             "unrelated-domain-accepted" => false
           }

    assert result.stats.worker_quality_draft_call_count_by_row |> Map.values() |> Enum.uniq() == [
             1
           ]

    assert result.stats.worker_quality_initial_critic_call_count_by_row
           |> Map.values()
           |> Enum.uniq() == [2]

    assert result.stats.worker_quality_revision_call_count_by_row == %{
             "restart-inaccuracy-repaired" => 1,
             "replay-guarantee-overclaim-repaired" => 1,
             "omitted-required-nuance-unresolved" => 1,
             "accurate-paraphrase-accepted" => 0,
             "unrelated-domain-accepted" => 0
           }

    assert result.stats.worker_quality_final_critic_call_count_by_row == %{
             "restart-inaccuracy-repaired" => 2,
             "replay-guarantee-overclaim-repaired" => 2,
             "omitted-required-nuance-unresolved" => 2,
             "accurate-paraphrase-accepted" => 0,
             "unrelated-domain-accepted" => 0
           }

    assert result.stats.worker_quality_initial_failed_rule_count_by_row == %{
             "restart-inaccuracy-repaired" => 1,
             "replay-guarantee-overclaim-repaired" => 1,
             "omitted-required-nuance-unresolved" => 1,
             "accurate-paraphrase-accepted" => 0,
             "unrelated-domain-accepted" => 0
           }

    assert result.stats.worker_quality_final_failed_rule_count_by_row == %{
             "restart-inaccuracy-repaired" => 0,
             "replay-guarantee-overclaim-repaired" => 0,
             "omitted-required-nuance-unresolved" => 1,
             "accurate-paraphrase-accepted" => nil,
             "unrelated-domain-accepted" => nil
           }

    for case_id <- [
          "restart-inaccuracy-repaired",
          "replay-guarantee-overclaim-repaired",
          "omitted-required-nuance-unresolved"
        ] do
      assert_received {:quality_eval_revision_call, ^case_id}
      assert_received {:quality_eval_critic_call, ^case_id, :final, "coverage_fidelity"}
      assert_received {:quality_eval_critic_call, ^case_id, :final, "safety_consistency"}
    end

    for case_id <- ["accurate-paraphrase-accepted", "unrelated-domain-accepted"] do
      refute_received {:quality_eval_revision_call, ^case_id}
      refute_received {:quality_eval_critic_call, ^case_id, :final, _group}
    end

    assert [record] = read_store(store)
    assert record["stats"]["protocol_provider_call_count"] == 24
    assert record["stats"]["configured_critic_invocation_count"] == 16
    assert record["stats"]["configured_revision_invocation_count"] == 3
    assert record["stats"]["phase_evidence_closed"] == true

    assert V13FanoutWorkerQualityEval.summary(result) ==
             "v13-fanout-worker-quality status=passed rows=5/5 protocol_calls=24 " <>
               "critic_invocations=16 revision_invocations=3 phases_closed=true"

    evidence = File.read!(store)
    refute evidence =~ "one_for_one"
    refute evidence =~ "exactly-once"
    refute evidence =~ "Team Blue"
    refute evidence =~ "mint container"
    refute evidence =~ "completion_preconditions"
    refute evidence =~ "preserve_supplied_semantics"
    refute evidence =~ "uncertainty_and_guarantees"
    refute evidence =~ "candidate"
  end

  test "typed critic results, not answer prose, decide the frozen expectations" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    result = run(fixture, critic: AcceptEverythingCritic)

    assert result.status == "failed"
    assert result.stats.protocol_provider_call_count == 15
    assert result.stats.configured_critic_invocation_count == 10
    assert result.stats.configured_revision_invocation_count == 0
    assert result.stats.phase_evidence_closed == true
    assert Enum.all?(result.rows, &(&1.rule_evidence_closed == true))

    assert result.failed_rows == [
             "restart-inaccuracy-repaired",
             "replay-guarantee-overclaim-repaired",
             "omitted-required-nuance-unresolved"
           ]

    assert Enum.take(result.rows, 2)
           |> Enum.all?(&(&1.failure_reason == "provider_call_count_mismatch"))

    assert Enum.at(result.rows, 2).failure_reason == "verdict_mismatch"
    assert Enum.drop(result.rows, 3) |> Enum.all?(&(&1.failure_stage == "none"))
    refute Enum.any?(result.rows, &Map.has_key?(&1, :failed_rule_ids))
  end

  test "wrong phase rules with the same six-call geometry fail the frozen rows" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result = run(fixture, critic: WrongRuleSameGeometryCritic, store: store)

    assert result.status == "failed"

    assert result.failed_rows == [
             "restart-inaccuracy-repaired",
             "omitted-required-nuance-unresolved"
           ]

    row = Enum.find(result.rows, &(&1.id == "restart-inaccuracy-repaired"))

    assert row.provider_call_count == 6
    assert row.initial_critic_call_count == 2
    assert row.revision_call_count == 1
    assert row.final_critic_call_count == 2
    assert row.failure_stage == "fixture_expectation"
    assert row.failure_reason == "initial_failed_rules_mismatch"
    refute Map.has_key?(row, :initial_failed_rule_ids)
    refute Map.has_key?(row, :final_failed_rule_ids)

    unresolved = Enum.find(result.rows, &(&1.id == "omitted-required-nuance-unresolved"))

    assert unresolved.provider_call_count == 6
    assert unresolved.failure_stage == "fixture_expectation"
    assert unresolved.failure_reason == "final_failed_rules_mismatch"
    refute Map.has_key?(unresolved, :initial_failed_rule_ids)
    refute Map.has_key?(unresolved, :final_failed_rule_ids)

    evidence = File.read!(store)
    refute evidence =~ "no_unsupplied_details"
    refute evidence =~ "uncertainty_and_guarantees"
    refute evidence =~ "completion_preconditions"
  end

  test "Worker metrics retain validated content-free protocol evidence by row" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result =
      run(fixture,
        critic: ScenarioCritic,
        runner_context: %{test_pid: self()},
        store: store
      )

    assert result.status == "passed"

    for key <- [
          :worker_quality_review_protocol_version_by_row,
          :worker_quality_rule_group_catalog_version_by_row
        ] do
      assert result.stats |> Map.fetch!(key) |> Map.values() |> Enum.uniq() == [1]
    end

    assert result.stats.worker_quality_critic_group_count_by_row
           |> Map.values()
           |> Enum.uniq() == [2]

    for key <- [
          :worker_quality_rule_group_catalog_sha256_by_row,
          :worker_quality_reviewer_config_sha256_by_row,
          :worker_quality_initial_assessment_sha256_by_row
        ] do
      assert result.stats
             |> Map.fetch!(key)
             |> Map.values()
             |> Enum.all?(&(is_binary(&1) and byte_size(&1) == 64))
    end

    assert result.stats.worker_quality_final_assessment_sha256_by_row == %{
             "restart-inaccuracy-repaired" =>
               result.rows |> Enum.at(0) |> Map.fetch!(:final_assessment_sha256),
             "replay-guarantee-overclaim-repaired" =>
               result.rows |> Enum.at(1) |> Map.fetch!(:final_assessment_sha256),
             "omitted-required-nuance-unresolved" =>
               result.rows |> Enum.at(2) |> Map.fetch!(:final_assessment_sha256),
             "accurate-paraphrase-accepted" => nil,
             "unrelated-domain-accepted" => nil
           }

    assert Enum.take(result.rows, 3)
           |> Enum.all?(
             &(is_binary(&1.final_assessment_sha256) and
                 byte_size(&1.final_assessment_sha256) == 64)
           )

    assert result.stats.worker_quality_accepted_assessment_sha256_by_row == %{
             "restart-inaccuracy-repaired" =>
               result.rows |> Enum.at(0) |> Map.fetch!(:accepted_assessment_sha256),
             "replay-guarantee-overclaim-repaired" =>
               result.rows |> Enum.at(1) |> Map.fetch!(:accepted_assessment_sha256),
             "omitted-required-nuance-unresolved" => nil,
             "accurate-paraphrase-accepted" =>
               result.rows |> Enum.at(3) |> Map.fetch!(:accepted_assessment_sha256),
             "unrelated-domain-accepted" =>
               result.rows |> Enum.at(4) |> Map.fetch!(:accepted_assessment_sha256)
           }

    assert result.rows
           |> Enum.reject(&(&1.verdict == "unresolved"))
           |> Enum.all?(
             &(is_binary(&1.accepted_assessment_sha256) and
                 byte_size(&1.accepted_assessment_sha256) == 64)
           )

    evidence = File.read!(store)
    assert evidence =~ "worker_quality_initial_assessment_sha256_by_row"
    refute evidence =~ "one_for_one"
    refute evidence =~ "Team Blue"
    refute evidence =~ "completion_preconditions"
    refute evidence =~ "source_handles"
    refute evidence =~ "candidate"
  end

  test "malformed group evidence fails closed without promoting a draft" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    result = run(fixture, critic: MalformedCritic)

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert result.stats.phase_evidence_closed == false
    assert Enum.all?(result.rows, &(&1.verdict == "invalid"))
    assert Enum.all?(result.rows, &(&1.rule_evidence_closed == false))
    assert Enum.all?(result.rows, &(&1.failure_stage == "initial_review"))
    assert Enum.all?(result.rows, &(&1.failure_reason == "initial_review_failed"))
    assert Enum.all?(result.rows, &is_nil(&1.receipt_version))
  end

  test "provider-supplied digest claims cannot forge passing Worker evidence" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result = run(fixture, critic: ForgedEvidenceCritic, store: store)

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert Enum.all?(result.rows, &(&1.failure_stage == "initial_review"))
    assert Enum.all?(result.rows, &(&1.failure_reason == "initial_review_failed"))

    for key <- [
          :worker_quality_reviewer_config_sha256_by_row,
          :worker_quality_initial_assessment_sha256_by_row,
          :worker_quality_final_assessment_sha256_by_row,
          :worker_quality_accepted_assessment_sha256_by_row
        ] do
      assert result.stats |> Map.fetch!(key) |> Map.values() |> Enum.uniq() == [nil]
    end

    refute File.read!(store) =~ String.duplicate("f", 64)
  end

  test "one outer row deadline bounds both critics and brutally stops unfinished work" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    started = System.monotonic_time(:millisecond)

    result =
      run(fixture,
        critic: SlowCritic,
        runner_context: %{test_pid: self()},
        row_timeout_ms: 10
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert result.stats.provider_call_count_closed == false
    assert Enum.all?(result.rows, &(&1.failure_stage == "deadline"))
    assert Enum.all?(result.rows, &(&1.failure_reason == "row_timeout"))
    assert elapsed_ms < 500

    for case_id <- Enum.map(fixture["scenarios"], & &1["id"]) do
      assert_received {:quality_eval_slow_critic, ^case_id}
    end
  end

  test "a completed row returned exactly at its outer absolute deadline is rejected" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    timeout_ms = 30_000

    result =
      run(fixture,
        row_timeout_ms: timeout_ms,
        row_monotonic_now: result_boundary_clock(timeout_ms, 0)
      )

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert result.stats.provider_call_count_closed == false
    assert Enum.all?(result.rows, &is_nil(&1.provider_call_count))
    assert Enum.all?(result.rows, &(&1.failure_stage == "deadline"))
    assert Enum.all?(result.rows, &(&1.failure_reason == "row_timeout"))
  end

  test "zero remaining outer time rejects a row before polling its task" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    timeout_ms = 30_000

    result =
      run(fixture,
        row_timeout_ms: timeout_ms,
        row_monotonic_now: remaining_boundary_clock(timeout_ms)
      )

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert result.stats.provider_call_count_closed == false
    assert Enum.all?(result.rows, &is_nil(&1.provider_call_count))
    assert Enum.all?(result.rows, &(&1.failure_stage == "deadline"))
    assert Enum.all?(result.rows, &(&1.failure_reason == "row_timeout"))
  end

  test "a completed row returned after its outer absolute deadline is rejected" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    timeout_ms = 30_000

    result =
      run(fixture,
        row_timeout_ms: timeout_ms,
        row_monotonic_now: result_boundary_clock(timeout_ms, 1)
      )

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert result.stats.provider_call_count_closed == false
    assert Enum.all?(result.rows, &is_nil(&1.provider_call_count))
    assert Enum.all?(result.rows, &(&1.failure_stage == "deadline"))
    assert Enum.all?(result.rows, &(&1.failure_reason == "row_timeout"))
  end

  test "a revision preflight failure cannot spend a synthetic call or reach final critics" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    Application.put_env(:allbert_assist, DirectAnswer, answerer: RevisionPreflightFailure)

    result =
      run(fixture,
        critic: ScenarioCritic,
        runner_context: %{test_pid: self()}
      )

    assert result.status == "failed"

    for case_id <- [
          "restart-inaccuracy-repaired",
          "replay-guarantee-overclaim-repaired",
          "omitted-required-nuance-unresolved"
        ] do
      assert %{
               provider_call_count: 3,
               failure_stage: "revision",
               failure_reason: "revision_failed"
             } =
               Enum.find(result.rows, &(&1.id == case_id))

      assert_received {:quality_eval_revision_preflight_failed, ^case_id}
      refute_received {:quality_eval_critic_call, ^case_id, :final, _group}
    end

    assert result.stats.configured_revision_invocation_count == 0
  end

  test "fixture rejects prose or regex oracles instead of turning examples into policy" do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    [first | rest] = fixture["scenarios"]

    for forbidden <- [
          Map.put(first, "expected_answer", "domain-specific prose"),
          Map.put(first, "answer_regex", "one_for_one"),
          put_in(first, ["expected", "answer_contains"], "opaque value")
        ] do
      path = write_fixture(%{fixture | "scenarios" => [forbidden | rest]})

      assert_raise RuntimeError, "invalid v1.3 fan-out worker-quality fixture", fn ->
        V13FanoutWorkerQualityEval.load_fixture!(path)
      end
    end
  end

  test "fixture pins the safe corpus, ordered scenarios, and phase call geometry" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    assert fixture["schema_version"] == 2

    assert Enum.map(fixture["scenarios"], fn scenario ->
             expected = scenario["expected"]

             {
               expected["initial_failed_rule_ids"],
               expected["final_failed_rule_ids"]
             }
           end) == [
             {["preserve_supplied_semantics"], []},
             {["uncertainty_and_guarantees"], []},
             {["completion_preconditions"], ["completion_preconditions"]},
             {[], nil},
             {[], nil}
           ]

    invalid_fixtures = [
      Map.put(fixture, "schema_version", 1),
      Map.put(fixture, "corpus_id", "v13-fanout-worker-quality-real-model-v2"),
      Map.put(fixture, "corpus_id", "unsafe\ncorpus"),
      put_in(fixture, ["scenarios", Access.at(0), "id"], "unsafe\nscenario"),
      put_in(fixture, ["scenarios", Access.at(0), "expected", "provider_call_count"], 2),
      put_in(fixture, ["scenarios", Access.at(3), "expected", "provider_call_count"], 4),
      put_in(fixture, ["scenarios", Access.at(0), "expected", "initial_failed_rule_ids"], []),
      put_in(fixture, ["scenarios", Access.at(2), "expected", "final_failed_rule_ids"], []),
      put_in(fixture, ["scenarios", Access.at(3), "expected", "final_failed_rule_ids"], [])
    ]

    for invalid_fixture <- invalid_fixtures do
      path = write_fixture(invalid_fixture)

      assert_raise RuntimeError, "invalid v1.3 fan-out worker-quality fixture", fn ->
        V13FanoutWorkerQualityEval.load_fixture!(path)
      end
    end
  end

  test "fixture digest binds the decoded frozen scenario bytes" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    changed =
      update_in(fixture, ["scenarios", Access.at(0), "draft"], fn draft ->
        draft <> " "
      end)

    path = write_fixture(changed)

    assert_raise RuntimeError, "invalid v1.3 fan-out worker-quality fixture digest", fn ->
      V13FanoutWorkerQualityEval.load_fixture!(path)
    end
  end

  defp run(fixture, opts) do
    defaults = [
      profile: @profile,
      critic: ScenarioCritic,
      runner_context: %{},
      store: :disabled,
      full_sha: @full_sha,
      dirty: false
    ]

    V13FanoutWorkerQualityEval.run(fixture, Keyword.merge(defaults, opts))
  end

  defp result_boundary_clock(timeout_ms, boundary_offset_ms) do
    calls = :atomics.new(1, [])
    base = System.monotonic_time(:millisecond)

    fn ->
      case rem(:atomics.add_get(calls, 1, 1) - 1, 3) do
        0 -> base
        1 -> base
        2 -> base + timeout_ms + boundary_offset_ms
      end
    end
  end

  defp remaining_boundary_clock(timeout_ms) do
    calls = :atomics.new(1, [])
    base = System.monotonic_time(:millisecond)

    fn ->
      case rem(:atomics.add_get(calls, 1, 1) - 1, 2) do
        0 -> base
        1 -> base + timeout_ms
      end
    end
  end

  defp write_fixture(fixture) do
    path =
      Path.join(
        System.tmp_dir!(),
        "v13-fanout-worker-quality-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(fixture))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp temp_store do
    Path.join(
      System.tmp_dir!(),
      "v13-fanout-worker-quality-#{System.unique_integer([:positive])}/runs.jsonl"
    )
  end

  defp read_store(store) do
    store
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
