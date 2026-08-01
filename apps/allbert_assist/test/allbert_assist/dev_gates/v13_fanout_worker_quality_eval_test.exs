defmodule AllbertAssist.DevGates.V13FanoutWorkerQualityEvalTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.V13FanoutWorkerQualityEval
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

  @fixture Path.expand("../../fixtures/v1.3/fanout_worker_quality_eval.json", __DIR__)
  @fixture_sha256 "7ed03c9e828492bcb6460ca7a540ffeffaf52a31b4139dbc0cb1f12829140b9b"
  @full_sha String.duplicate("a", 40)
  @profile %{
    name: "direct_answer_local",
    provider: "local_ollama",
    model: "qwen2.5:7b"
  }

  defmodule ScenarioReviewer do
    @config_digest String.duplicate("b", 64)

    def prepare(contract, draft, context) do
      send(context.test_pid, {:review_prepared, context.quality_eval_case_id})

      {:ok,
       %{
         contract: contract,
         draft: draft,
         reviewer_config_sha256: @config_digest
       }}
    end

    def invoke(prepared, context) do
      send(context.test_pid, {:review_invoked, context.quality_eval_case_id})

      {final_answer, verdict, failed_rule_ids} = scenario(context.quality_eval_case_id, prepared)

      rule_results =
        Enum.map(QualityPolicy.rule_ids(), fn rule_id ->
          verdict = if rule_id in failed_rule_ids, do: "unsatisfied", else: "satisfied"
          %{"rule_id" => rule_id, "verdict" => verdict}
        end)

      {:ok,
       %{
         final_answer: final_answer,
         verdict: verdict,
         rule_results: rule_results,
         failed_rule_ids: failed_rule_ids,
         reviewer_config_sha256: @config_digest
       }}
    end

    defp scenario("restart-inaccuracy-repaired", prepared),
      do: {prepared.draft <> " Reviewed correction.", "accepted", []}

    defp scenario("replay-guarantee-overclaim-repaired", prepared),
      do: {prepared.draft <> " Reviewed correction.", "accepted", []}

    defp scenario("omitted-required-nuance-unresolved", prepared),
      do: {prepared.draft, "unresolved", ["requested_dimensions"]}

    defp scenario(_accepted_case, prepared), do: {prepared.draft, "accepted", []}
  end

  defmodule WrongVerdictReviewer do
    @config_digest String.duplicate("c", 64)

    def prepare(contract, draft, _context),
      do: {:ok, %{contract: contract, draft: draft, reviewer_config_sha256: @config_digest}}

    def invoke(prepared, _context) do
      {:ok,
       %{
         final_answer: prepared.draft,
         verdict: "accepted",
         rule_results:
           Enum.map(QualityPolicy.rule_ids(), &%{"rule_id" => &1, "verdict" => "satisfied"}),
         failed_rule_ids: [],
         reviewer_config_sha256: @config_digest
       }}
    end
  end

  defmodule DuplicateRuleReviewer do
    @config_digest String.duplicate("d", 64)

    def prepare(contract, draft, _context),
      do: {:ok, %{contract: contract, draft: draft, reviewer_config_sha256: @config_digest}}

    def invoke(prepared, _context) do
      [first | rest] = QualityPolicy.rule_ids()

      rule_results =
        [%{"rule_id" => first, "verdict" => "satisfied"}] ++
          Enum.map(rest, &%{"rule_id" => &1, "verdict" => "satisfied"}) ++
          [%{"rule_id" => first, "verdict" => "satisfied"}]

      {:ok,
       %{
         final_answer: prepared.draft,
         verdict: "accepted",
         rule_results: rule_results,
         failed_rule_ids: [],
         reviewer_config_sha256: @config_digest
       }}
    end
  end

  defmodule MismatchedConfigReviewer do
    @prepared_digest String.duplicate("e", 64)
    @returned_digest String.duplicate("f", 64)

    def prepare(contract, draft, _context) do
      {:ok,
       %{
         contract: contract,
         draft: draft,
         reviewer_config_sha256: @prepared_digest
       }}
    end

    def invoke(prepared, _context) do
      {:ok,
       %{
         final_answer: prepared.draft <> " Changed bytes.",
         verdict: "accepted",
         rule_results:
           Enum.map(QualityPolicy.rule_ids(), &%{"rule_id" => &1, "verdict" => "satisfied"}),
         failed_rule_ids: [],
         reviewer_config_sha256: @returned_digest
       }}
    end
  end

  defmodule ExtraFailedRuleReviewer do
    @config_digest String.duplicate("1", 64)

    def prepare(contract, draft, _context) do
      {:ok,
       %{
         contract: contract,
         draft: draft,
         reviewer_config_sha256: @config_digest
       }}
    end

    def invoke(prepared, context) do
      failed_rule_ids =
        if context.quality_eval_case_id == "omitted-required-nuance-unresolved",
          do: ["requested_dimensions", "internal_consistency"],
          else: []

      verdict = if failed_rule_ids == [], do: "accepted", else: "unresolved"

      rule_results =
        Enum.map(QualityPolicy.rule_ids(), fn rule_id ->
          rule_verdict = if rule_id in failed_rule_ids, do: "unsatisfied", else: "satisfied"
          %{"rule_id" => rule_id, "verdict" => rule_verdict}
        end)

      final_answer =
        if context.quality_eval_case_id in [
             "restart-inaccuracy-repaired",
             "replay-guarantee-overclaim-repaired"
           ],
           do: prepared.draft <> " Changed bytes.",
           else: prepared.draft

      {:ok,
       %{
         final_answer: final_answer,
         verdict: verdict,
         rule_results: rule_results,
         failed_rule_ids: failed_rule_ids,
         reviewer_config_sha256: @config_digest
       }}
    end
  end

  defmodule SlowReviewer do
    @config_digest String.duplicate("2", 64)

    def prepare(contract, draft, _context) do
      {:ok,
       %{
         contract: contract,
         draft: draft,
         reviewer_config_sha256: @config_digest
       }}
    end

    def invoke(_prepared, context) do
      send(context.test_pid, {:slow_review_invoked, context.quality_eval_case_id})
      Process.sleep(1_000)
      {:error, :should_have_timed_out}
    end
  end

  defmodule SlowPrepareReviewer do
    @config_digest String.duplicate("3", 64)

    def prepare(contract, draft, context) do
      send(context.test_pid, {:slow_prepare_started, context.quality_eval_case_id})
      Process.sleep(100)

      {:ok,
       %{
         contract: contract,
         draft: draft,
         reviewer_config_sha256: @config_digest
       }}
    end

    def invoke(_prepared, context) do
      send(context.test_pid, {:invoke_after_slow_prepare, context.quality_eval_case_id})
      {:error, :must_not_invoke_after_prepare_timeout}
    end
  end

  defmodule PrepareFailureReviewer do
    def prepare(_contract, _draft, _context), do: {:error, :transport_denied}
    def invoke(_prepared, _context), do: raise("must not invoke after prepare failure")
  end

  defmodule InvokeFailureReviewer do
    def prepare(contract, draft, _context), do: {:ok, %{contract: contract, draft: draft}}
    def invoke(_prepared, _context), do: {:error, :timeout}
  end

  test "task-neutral scenario matrix closes semantic verdict, rule evidence, and call counts" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: ScenarioReviewer,
        reviewer_context: %{test_pid: self()},
        store: store,
        full_sha: @full_sha,
        dirty: false
      )

    assert result.status == "passed"
    assert result.failed_rows == []

    assert result.stats == %{
             profile: "direct_answer_local",
             worker_quality_rows: 5,
             worker_quality_rows_passed: 5,
             accepted_rows: 4,
             unresolved_rows: 1,
             protocol_provider_call_count: 10,
             configured_reviewer_invocation_count: 5,
             fixture_sha256: @fixture_sha256,
             required_change_rows: 2,
             required_change_rows_changed: 2,
             optional_change_rows_changed: 0,
             required_changes_closed: true,
             rule_catalog_version: 1,
             rule_count: length(QualityPolicy.rule_ids()),
             rule_evidence_closed: true
           }

    assert Enum.map(result.rows, &{&1.id, &1.verdict, &1.provider_call_count}) == [
             {"restart-inaccuracy-repaired", "accepted", 2},
             {"replay-guarantee-overclaim-repaired", "accepted", 2},
             {"omitted-required-nuance-unresolved", "unresolved", 2},
             {"accurate-paraphrase-accepted", "accepted", 2},
             {"unrelated-domain-accepted", "accepted", 2}
           ]

    assert Enum.all?(result.rows, & &1.rule_evidence_closed)
    assert Enum.all?(result.rows, &(&1.configured_reviewer_invocation_count == 1))

    assert Enum.map(result.rows, &{&1.id, &1.answer_changed}) == [
             {"restart-inaccuracy-repaired", true},
             {"replay-guarantee-overclaim-repaired", true},
             {"omitted-required-nuance-unresolved", false},
             {"accurate-paraphrase-accepted", false},
             {"unrelated-domain-accepted", false}
           ]

    for case_id <- Enum.map(fixture["scenarios"], & &1["id"]) do
      assert_received {:review_prepared, ^case_id}
      assert_received {:review_invoked, ^case_id}
    end

    assert [record] = read_store(store)
    assert record["gate"] == "bench-v13-fanout"
    assert record["phase_or_step"] == "worker-quality"
    assert record["corpus_id"] == "v13-fanout-worker-quality-real-model-v1"
    assert record["status"] == "passed"
    assert record["full_sha"] == @full_sha
    assert record["dirty"] == false
    assert record["stats"]["protocol_provider_call_count"] == 10
    assert record["stats"]["configured_reviewer_invocation_count"] == 5
    assert record["stats"]["fixture_sha256"] == @fixture_sha256
    assert record["stats"]["required_change_rows"] == 2
    assert record["stats"]["required_change_rows_changed"] == 2
    assert record["stats"]["optional_change_rows_changed"] == 0
    assert record["stats"]["required_changes_closed"] == true
    assert record["stats"]["rule_evidence_closed"] == true

    assert V13FanoutWorkerQualityEval.summary(result) ==
             "v13-fanout-worker-quality status=passed rows=5/5 protocol_calls=10 " <>
               "reviewer_invocations=5 rules_closed=true"

    evidence = File.read!(store)
    refute evidence =~ "one_for_one"
    refute evidence =~ "exactly-once"
    refute evidence =~ "Team Blue"
    refute evidence =~ "mint container"
    refute evidence =~ "Reviewed correction"
    refute evidence =~ "configured_provider_call_count"
  end

  test "a semantically wrong closed verdict fails its scenario without inspecting answer prose" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    result =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: WrongVerdictReviewer,
        reviewer_context: %{},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"

    assert "omitted-required-nuance-unresolved" in result.failed_rows
    assert "restart-inaccuracy-repaired" in result.failed_rows
    assert "replay-guarantee-overclaim-repaired" in result.failed_rows
  end

  test "duplicated or extra reviewer rule evidence fails closed" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    result =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: DuplicateRuleReviewer,
        reviewer_context: %{},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert result.stats.rule_evidence_closed == false
    assert Enum.all?(result.rows, &(&1.provider_call_count == 2))
    assert Enum.all?(result.rows, &(&1.configured_reviewer_invocation_count == 1))
  end

  test "reviewer evidence must bind the exact prepared reviewer configuration" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    result =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: MismatchedConfigReviewer,
        reviewer_context: %{},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"
    assert result.stats.worker_quality_rows_passed == 0
    assert result.stats.protocol_provider_call_count == 10
    assert result.stats.configured_reviewer_invocation_count == 5
    assert Enum.all?(result.rows, &(&1.rule_evidence_closed == false))
  end

  test "expected failed rules are exact rather than a permissive subset" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    result =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: ExtraFailedRuleReviewer,
        reviewer_context: %{},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"
    assert result.failed_rows == ["omitted-required-nuance-unresolved"]

    assert %{failed_rule_ids: ["requested_dimensions", "internal_consistency"], passed?: false} =
             Enum.find(result.rows, &(&1.id == "omitted-required-nuance-unresolved"))
  end

  test "a slow invoked reviewer is killed at the outer row timeout and counted once" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    result =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: SlowReviewer,
        reviewer_context: %{test_pid: self()},
        row_timeout_ms: 10,
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"
    assert result.stats.protocol_provider_call_count == 10
    assert result.stats.configured_reviewer_invocation_count == 5
    assert Enum.all?(result.rows, &(&1.provider_call_count == 2))
    assert Enum.all?(result.rows, &(&1.configured_reviewer_invocation_count == 1))

    for case_id <- Enum.map(fixture["scenarios"], & &1["id"]) do
      assert_received {:slow_review_invoked, ^case_id}
    end
  end

  test "one row deadline bounds preparation and prevents invocation after prepare timeout" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)
    started = System.monotonic_time(:millisecond)

    result =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: SlowPrepareReviewer,
        reviewer_context: %{test_pid: self()},
        row_timeout_ms: 5,
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    elapsed_ms = System.monotonic_time(:millisecond) - started

    assert result.status == "failed"
    assert result.stats.protocol_provider_call_count == 5
    assert result.stats.configured_reviewer_invocation_count == 0
    assert Enum.all?(result.rows, &(&1.provider_call_count == 1))
    assert Enum.all?(result.rows, &(&1.configured_reviewer_invocation_count == 0))
    assert elapsed_ms < 300

    for case_id <- Enum.map(fixture["scenarios"], & &1["id"]) do
      assert_received {:slow_prepare_started, ^case_id}
      refute_received {:invoke_after_slow_prepare, ^case_id}
    end
  end

  test "provider accounting distinguishes pre-invocation denial from an invoked failure" do
    fixture = V13FanoutWorkerQualityEval.load_fixture!(@fixture)

    prepare_failure =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: PrepareFailureReviewer,
        reviewer_context: %{},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert prepare_failure.status == "failed"
    assert prepare_failure.stats.protocol_provider_call_count == 5
    assert prepare_failure.stats.configured_reviewer_invocation_count == 0
    assert Enum.all?(prepare_failure.rows, &(&1.provider_call_count == 1))
    assert Enum.all?(prepare_failure.rows, &(&1.configured_reviewer_invocation_count == 0))

    invoke_failure =
      V13FanoutWorkerQualityEval.run(fixture,
        profile: @profile,
        reviewer: InvokeFailureReviewer,
        reviewer_context: %{},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert invoke_failure.status == "failed"
    assert invoke_failure.stats.protocol_provider_call_count == 10
    assert invoke_failure.stats.configured_reviewer_invocation_count == 5
    assert Enum.all?(invoke_failure.rows, &(&1.provider_call_count == 2))
    assert Enum.all?(invoke_failure.rows, &(&1.configured_reviewer_invocation_count == 1))
  end

  test "fixture rejects response or regex oracles instead of turning examples into policy" do
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

  test "fixture pins the safe corpus and ordered safe scenario identifiers" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    invalid_fixtures = [
      Map.put(fixture, "corpus_id", "v13-fanout-worker-quality-real-model-v2"),
      Map.put(fixture, "corpus_id", "unsafe\ncorpus"),
      put_in(fixture, ["scenarios", Access.at(0), "id"], "unsafe\nscenario")
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
