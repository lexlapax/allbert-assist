defmodule AllbertAssist.DevGates.V13FanoutEvalTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.{V13FanoutEval, V13FanoutWorkerQualityEval}
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

  @fixture Path.expand("../../fixtures/v1.3/fanout_real_model_eval.json", __DIR__)
  @worker_fixture Path.expand("../../fixtures/v1.3/fanout_worker_quality_eval.json", __DIR__)
  @fixture_sha256 "9478e8890a25fb0254b00f7f6ee8185836d28ad2ce62776e56af500f127a672f"
  @worker_fixture_sha256 "7ed03c9e828492bcb6460ca7a540ffeffaf52a31b4139dbc0cb1f12829140b9b"
  @full_sha String.duplicate("a", 40)
  @profile %{
    name: "direct_answer_local",
    provider: "local_ollama",
    model: "qwen2.5:7b"
  }

  defmodule QualifiedReviewer do
    @config_digest String.duplicate("b", 64)

    def prepare(contract, draft, _context),
      do: {:ok, %{contract: contract, draft: draft, reviewer_config_sha256: @config_digest}}

    def invoke(prepared, context) do
      {final_answer, verdict, failed_rule_ids} =
        case context.quality_eval_case_id do
          id
          when id in [
                 "restart-inaccuracy-repaired",
                 "replay-guarantee-overclaim-repaired"
               ] ->
            {prepared.draft <> " Reviewed correction.", "accepted", []}

          "omitted-required-nuance-unresolved" ->
            {prepared.draft, "unresolved", ["requested_dimensions"]}

          _accepted ->
            {prepared.draft, "accepted", []}
        end

      rule_results =
        Enum.map(QualityPolicy.rule_ids(), fn rule_id ->
          rule_verdict = if rule_id in failed_rule_ids, do: "unsatisfied", else: "satisfied"
          %{"rule_id" => rule_id, "verdict" => rule_verdict}
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
  end

  defmodule FailingReviewer do
    def prepare(_contract, _draft, _context), do: {:error, :reviewer_unavailable}
    def invoke(_prepared, _context), do: raise("must not invoke after prepare failure")
  end

  test "focused qualification accepts structured manager and composer outcomes" do
    fixture = V13FanoutEval.load_fixture!(@fixture)
    parent = self()
    manager = qualified_manager(fixture, parent)
    composer = qualified_composer(parent)

    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result =
      V13FanoutEval.run(fixture,
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: manager,
        composer: composer,
        composer_context: %{timeout_ms: 10_000, max_output_tokens: 1_024},
        store: store,
        full_sha: @full_sha,
        dirty: false
      )

    assert result.status == "passed"
    assert result.failed_rows == []

    assert result.stats == %{
             profile: "direct_answer_local",
             fixture_sha256: @fixture_sha256,
             manager_rows: 2,
             manager_rows_passed: 2,
             supplied_data_kind: "answer",
             supplied_data_child_count: 0,
             supplied_data_join_role: "none",
             supplied_data_policy_outcome: "supplied_data",
             supplied_data_manager_attempts: 1,
             supplied_data_reviewed: true,
             adaptive_kind: "fanout",
             adaptive_child_count: 2,
             adaptive_join_role: "parent_presentation_only",
             adaptive_policy_outcome: "independent_advisory",
             adaptive_manager_attempts: 1,
             adaptive_reviewed: true,
             composition_layout_version: 1,
             composition_relationship: "complementary",
             composition_ordered_queue_positions: [0, 1],
             composition_valid: true
           }

    assert_received {:manager, supplied_prompt, %{model_profile: @profile}}
    assert supplied_prompt == manager_case(fixture, "fov3-supplied-data")["prompt"]

    assert_received {:manager, architecture_prompt, %{model_profile: @profile}}
    assert architecture_prompt == manager_case(fixture, "fov4-independent-architecture")["prompt"]

    assert_received {:composer, snapshot, @profile,
                     %{max_output_tokens: 1_024, timeout_ms: 10_000}}

    assert Enum.map(snapshot.children, & &1.queue_position) == [0, 1]
    assert Enum.map(snapshot.children, & &1.status) == ["completed", "completed"]

    assert [record] = read_store(store)
    assert record["gate"] == "bench-v13-fanout"
    assert record["corpus_id"] == "v13-fanout-real-model-v1"
    assert record["status"] == "passed"
    assert record["full_sha"] == @full_sha
    assert record["dirty"] == false
    assert record["stats"]["fixture_sha256"] == @fixture_sha256
    assert record["stats"]["composition_ordered_queue_positions"] == [0, 1]

    evidence = File.read!(store)
    refute evidence =~ "archive logs"
    refute evidence =~ "restart intensity"
    refute evidence =~ "fixture-sensitive"
    refute evidence =~ "idempotent replay"
  end

  test "focused qualification fails closed on a structurally wrong manager outcome" do
    fixture = V13FanoutEval.load_fixture!(@fixture)

    manager = fn _text, _context ->
      {:ok,
       %{
         kind: :answer,
         message: "not inspected by the harness",
         diagnostic: %{
           attempts: 1,
           join_role: :none,
           policy_outcome: :supplied_data,
           work_unit_count: 0,
           reviewed?: true
         }
       }}
    end

    result =
      V13FanoutEval.run(fixture,
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: manager,
        composer: fn _snapshot, _profile, _context ->
          flunk("composer must not run after the fan-out row fails")
        end,
        composer_context: %{timeout_ms: 10_000, max_output_tokens: 1_024},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"
    assert result.failed_rows == ["fov4-independent-architecture", "composer-complementary"]
    assert result.stats.adaptive_kind == "answer"
    assert result.stats.adaptive_child_count == 0
    assert result.stats.composition_valid == false
  end

  test "manager/composer fixture digest binds the decoded frozen corpus" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    changed =
      update_in(fixture, ["composition", "child_results", Access.at(0), "detail"], fn detail ->
        detail <> " "
      end)

    path = write_fixture(changed)

    assert_raise RuntimeError, "invalid v1.3 fan-out fixture digest", fn ->
      V13FanoutEval.load_fixture!(path)
    end
  end

  test "public two-phase orchestration runs both rows and stores content-free provenance" do
    fixtures = V13FanoutEval.load_fixtures!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result =
      V13FanoutEval.run_phases(
        fixtures,
        phase_options(fixtures,
          store: store,
          reviewer: QualifiedReviewer
        )
      )

    assert result.status == "passed"
    assert result.failed_rows == []
    assert result.manager_and_composer.status == "passed"
    assert result.worker_quality.status == "passed"

    assert [manager_record, worker_record] = read_store(store)

    assert Enum.map([manager_record, worker_record], & &1["phase_or_step"]) == [
             "manager-and-composer",
             "worker-quality"
           ]

    assert manager_record["stats"]["fixture_sha256"] == @fixture_sha256
    assert worker_record["stats"]["fixture_sha256"] == @worker_fixture_sha256

    evidence = File.read!(store)
    assert evidence =~ @fixture_sha256
    assert evidence =~ @worker_fixture_sha256
    refute evidence =~ Path.basename(@fixture)
    refute evidence =~ Path.basename(@worker_fixture)
    refute evidence =~ "archive logs"
    refute evidence =~ "one_for_one"
    refute evidence =~ "Reviewed correction"
  end

  test "public two-phase orchestration combines worker failure with a passing manager phase" do
    fixtures = V13FanoutEval.load_fixtures!(@fixture, @worker_fixture)

    result =
      V13FanoutEval.run_phases(
        fixtures,
        phase_options(fixtures,
          store: :disabled,
          reviewer: FailingReviewer
        )
      )

    assert result.status == "failed"
    assert result.manager_and_composer.status == "passed"
    assert result.worker_quality.status == "failed"
    assert result.failed_rows == Enum.map(fixtures.worker_quality["scenarios"], & &1["id"])
    assert result.worker_quality.stats.configured_reviewer_invocation_count == 0
  end

  test "fixture bundle routing honors default sibling and explicit worker paths" do
    root =
      Path.join(System.tmp_dir!(), "v13-fanout-bundle-#{System.unique_integer([:positive])}")

    default_root = Path.join(root, "default")
    explicit_root = Path.join(root, "explicit")
    File.mkdir_p!(default_root)
    File.mkdir_p!(explicit_root)
    on_exit(fn -> File.rm_rf!(root) end)

    default_manager = Path.join(default_root, "fanout_real_model_eval.json")
    default_worker = Path.join(default_root, "fanout_worker_quality_eval.json")
    File.cp!(@fixture, default_manager)
    File.cp!(@worker_fixture, default_worker)

    default = V13FanoutEval.load_fixtures!(default_manager)
    assert V13FanoutEval.fixture_sha256(default.manager_and_composer) == @fixture_sha256

    assert V13FanoutWorkerQualityEval.fixture_sha256(default.worker_quality) ==
             @worker_fixture_sha256

    explicit_manager = Path.join(explicit_root, "fanout_real_model_eval.json")
    invalid_sibling = Path.join(explicit_root, "fanout_worker_quality_eval.json")
    explicit_worker = Path.join(root, "selected-worker.json")
    File.cp!(@fixture, explicit_manager)
    File.write!(invalid_sibling, "{}")
    File.cp!(@worker_fixture, explicit_worker)

    explicit = V13FanoutEval.load_fixtures!(explicit_manager, explicit_worker)
    assert V13FanoutEval.fixture_sha256(explicit.manager_and_composer) == @fixture_sha256

    assert V13FanoutWorkerQualityEval.fixture_sha256(explicit.worker_quality) ==
             @worker_fixture_sha256
  end

  defp qualified_manager(fixture, parent) do
    fn text, context ->
      send(parent, {:manager, text, context})

      case case_id(fixture, text) do
        "fov3-supplied-data" ->
          {:ok,
           %{
             kind: :answer,
             message: "fixture-sensitive supplied-data answer",
             diagnostic: %{
               attempts: 1,
               join_role: :none,
               policy_outcome: :supplied_data,
               work_unit_count: 0,
               reviewed?: true
             }
           }}

        "fov4-independent-architecture" ->
          {:ok, plan} =
            FanoutPlan.compile(
              text,
              [
                %{
                  title: "OTP supervision",
                  objective: "Analyze OTP supervision isolation and restart policy.",
                  expected_result: "A bounded OTP finding."
                },
                %{
                  title: "Event-log recovery",
                  objective: "Analyze event-log replay and projection recovery.",
                  expected_result: "A bounded recovery finding."
                }
              ],
              source: :model
            )

          {:ok,
           %{
             kind: :fanout,
             plan: plan,
             fallback_answer: "fixture-sensitive architecture answer",
             diagnostic: %{
               attempts: 1,
               join_role: :parent_presentation_only,
               policy_outcome: :independent_advisory,
               work_unit_count: 2,
               reviewed?: true
             }
           }}
      end
    end
  end

  defp qualified_composer(parent) do
    fn snapshot, profile, context ->
      send(parent, {:composer, snapshot, profile, context})

      {:ok,
       %{
         sections: [
           %{relationship: "complementary", ordered_queue_positions: [0, 1]}
         ]
       }}
    end
  end

  defp phase_options(fixtures, opts) do
    store = Keyword.fetch!(opts, :store)

    [
      manager_and_composer: [
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: qualified_manager(fixtures.manager_and_composer, self()),
        composer: qualified_composer(self()),
        composer_context: %{timeout_ms: 10_000, max_output_tokens: 1_024},
        store: store,
        full_sha: @full_sha,
        dirty: false
      ],
      worker_quality: [
        profile: @profile,
        reviewer: Keyword.fetch!(opts, :reviewer),
        reviewer_context: %{},
        row_timeout_ms: 100,
        store: store,
        full_sha: @full_sha,
        dirty: false
      ]
    ]
  end

  defp case_id(fixture, text) do
    fixture
    |> Map.fetch!("manager_cases")
    |> Enum.find(&(&1["prompt"] == text))
    |> Map.fetch!("id")
  end

  defp manager_case(fixture, id) do
    Enum.find(fixture["manager_cases"], &(&1["id"] == id))
  end

  defp temp_store do
    Path.join(
      System.tmp_dir!(),
      "v13-fanout-eval-#{System.unique_integer([:positive])}/runs.jsonl"
    )
  end

  defp write_fixture(fixture) do
    path =
      Path.join(
        System.tmp_dir!(),
        "v13-fanout-manager-#{System.unique_integer([:positive])}.json"
      )

    File.write!(path, Jason.encode!(fixture))
    on_exit(fn -> File.rm(path) end)
    path
  end

  defp read_store(store) do
    store
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
