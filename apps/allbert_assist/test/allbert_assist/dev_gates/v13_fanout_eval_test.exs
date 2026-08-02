defmodule AllbertAssist.DevGates.V13FanoutEvalTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.{V13FanoutEval, V13FanoutWorkerQualityEval}
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

  @fixture Path.expand("../../fixtures/v1.3/fanout_real_model_eval.json", __DIR__)
  @worker_fixture Path.expand("../../fixtures/v1.3/fanout_worker_quality_eval.json", __DIR__)
  @fixture_sha256 "59c2b74ec85f004cea27ad0c5088eeb5f1ea98f3cf45dd3949524f41f6f93f99"
  @worker_fixture_sha256 "35992f6ee830e8f36af4cb80d4c08b1be5617d26bb3687377d1d12c146d8b425"
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
            {prepared.draft, "unresolved", ["completion_preconditions"]}

          _accepted ->
            {prepared.draft, "accepted", []}
        end

      violations = Map.new(QualityPolicy.rule_ids(), &{&1, &1 in failed_rule_ids})

      {:ok, normalized} =
        QualityPolicy.validate_review(%{
          "final_answer" => final_answer,
          "rule_violations" => violations
        })

      if normalized.verdict != verdict,
        do: raise("fixture verdict does not match locally derived rule evidence")

      {:ok, Map.put(normalized, :reviewer_config_sha256, @config_digest)}
    end
  end

  defmodule FailingReviewer do
    def prepare(_contract, _draft, _context), do: {:error, :reviewer_unavailable}
    def invoke(_prepared, _context), do: raise("must not invoke after prepare failure")
  end

  defmodule QualifiedSynthesisClient do
    alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

    def compose(snapshot, _profile, context) do
      send(context.test_pid, {:synthesis_client, snapshot})

      {:ok,
       %{
         sections: sections(snapshot.parent_id),
         advisory_synthesis:
           "The reviewed observations support the selected relationship while durable status and receipt truth remain authoritative in Allbert.",
         review: %{
           verdict: "accepted",
           rule_results:
             Enum.map(SynthesisPolicy.rule_ids(), &%{rule_id: &1, verdict: "satisfied"}),
           covered_queue_positions: completed_positions(snapshot)
         }
       }}
    end

    defp sections("v13-composer-complementary-architecture"),
      do: [%{relationship: "complementary", ordered_queue_positions: [0, 1]}]

    defp sections("v13-composer-contrasting-energy"),
      do: [%{relationship: "contrasting", ordered_queue_positions: [0, 1]}]

    defp sections("v13-composer-sequential-incident-response"),
      do: [%{relationship: "sequential", ordered_queue_positions: [0, 1]}]

    defp sections("v13-composer-supporting-archaeology"),
      do: [%{relationship: "supporting", ordered_queue_positions: [0, 1]}]

    defp sections("v13-composer-independent-travel") do
      [
        %{relationship: "supporting", ordered_queue_positions: [0, 1]},
        %{relationship: "independent", ordered_queue_positions: [2]}
      ]
    end

    defp sections("v13-composer-partial-data-migration"),
      do: [%{relationship: "independent", ordered_queue_positions: [0]}]

    defp sections("v13-composer-unrelated-domain-culinary"),
      do: [%{relationship: "complementary", ordered_queue_positions: [0, 1]}]

    defp completed_positions(snapshot) do
      snapshot.children
      |> Enum.filter(&(&1.status == "completed"))
      |> Enum.map(& &1.queue_position)
      |> Enum.sort()
    end
  end

  defmodule SensitiveProviderFailureClient do
    def compose(_snapshot, _profile, _context),
      do: {:error, {:provider_failed, "sensitive provider body must never enter metrics"}}
  end

  defmodule ClassifiedFailureSynthesisClient do
    def compose(_snapshot, _profile, context), do: Map.fetch!(context, :failure_result)
  end

  test "focused qualification accepts seven reviewed v2 syntheses through the lifecycle" do
    fixture = V13FanoutEval.load_fixture!(@fixture)
    parent = self()
    manager = qualified_manager(fixture, parent)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result =
      V13FanoutEval.run(fixture,
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: manager,
        composer_client: QualifiedSynthesisClient,
        composer_authorizer: fn profile, context ->
          send(parent, {:composer_authorized, profile, context})
          :ok
        end,
        composer_context: %{
          timeout_ms: 10_000,
          max_output_tokens: 1_024,
          test_pid: self()
        },
        store: store,
        full_sha: @full_sha,
        dirty: false
      )

    assert result.status == "passed"
    assert result.failed_rows == []

    assert result.stats.profile == "direct_answer_local"
    assert result.stats.fixture_sha256 == @fixture_sha256
    assert result.stats.manager_rows == 2
    assert result.stats.manager_rows_passed == 2
    assert result.stats.supplied_data_kind == "answer"
    assert result.stats.supplied_data_policy_outcome == "supplied_data"
    assert result.stats.adaptive_kind == "fanout"
    assert result.stats.adaptive_child_count == 2
    assert result.stats.adaptive_join_role == "parent_presentation_only"
    assert result.stats.composition_rows == 7
    assert result.stats.composition_rows_passed == 7
    assert result.stats.composition_layout_version == 2
    assert result.stats.composition_relationship == "complementary"
    assert result.stats.composition_ordered_queue_positions == [0, 1]
    assert result.stats.composition_domain_count == 7

    assert result.stats.composition_relationship_counts == %{
             "complementary" => 2,
             "contrasting" => 1,
             "independent" => 2,
             "sequential" => 1,
             "supporting" => 2
           }

    assert result.stats.composition_valid == true

    assert_received {:manager, supplied_prompt, %{model_profile: @profile}}
    assert supplied_prompt == manager_case(fixture, "fov3-supplied-data")["prompt"]

    assert_received {:manager, architecture_prompt, %{model_profile: @profile}}
    assert architecture_prompt == manager_case(fixture, "fov4-independent-architecture")["prompt"]

    composition_rows = result.rows

    assert Enum.map(composition_rows, & &1.id) ==
             Enum.map(fixture["composition_cases"], & &1["id"])

    assert Enum.all?(composition_rows, &(&1.layout_version == 2))
    assert Enum.all?(composition_rows, &(&1.failure_stage == "none"))
    assert Enum.all?(composition_rows, &(&1.failure_reason == "none"))

    assert Enum.all?(composition_rows, fn row ->
             Enum.all?(
               [row.body_sha256, row.provenance_sha256, row.selection_sha256],
               &(is_binary(&1) and byte_size(&1) == 64)
             )
           end)

    assert result.stats.composition_body_sha256_by_row ==
             Map.new(composition_rows, &{&1.id, &1.body_sha256})

    assert result.stats.composition_provenance_sha256_by_row ==
             Map.new(composition_rows, &{&1.id, &1.provenance_sha256})

    assert result.stats.composition_selection_sha256_by_row ==
             Map.new(composition_rows, &{&1.id, &1.selection_sha256})

    for composition_case <- fixture["composition_cases"] do
      assert_received {:composer_authorized, @profile, %{test_pid: test_pid}}
      assert test_pid == self()
      assert_received {:synthesis_client, snapshot}
      assert snapshot.version == 2
      assert snapshot.parent_id == composition_case["snapshot"]["parent_id"]

      for child <- Enum.filter(snapshot.children, &(&1.status == "completed")) do
        assert child.result_authority == "reviewed_advisory"
        assert byte_size(child.quality_receipt_sha256) == 64
      end
    end

    assert [record] = read_store(store)
    assert record["gate"] == "bench-v13-fanout"
    assert record["corpus_id"] == "v13-fanout-real-model-v2"
    assert record["status"] == "passed"
    assert record["full_sha"] == @full_sha
    assert record["dirty"] == false
    assert record["stats"]["fixture_sha256"] == @fixture_sha256
    assert record["stats"]["composition_ordered_queue_positions"] == [0, 1]
    assert record["stats"]["composition_rows_passed"] == 7

    assert record["stats"]["composition_body_sha256_by_row"] ==
             result.stats.composition_body_sha256_by_row

    assert record["stats"]["composition_provenance_sha256_by_row"] ==
             result.stats.composition_provenance_sha256_by_row

    assert record["stats"]["composition_selection_sha256_by_row"] ==
             result.stats.composition_selection_sha256_by_row

    evidence = File.read!(store)
    refute evidence =~ "archive logs"
    refute evidence =~ "restart intensity"
    refute evidence =~ "fixture-sensitive"
    refute evidence =~ "idempotent replay"
    refute evidence =~ "Energy storage trade-off"
    refute evidence =~ "Bread fermentation brief"
    refute evidence =~ "durable status and receipt truth"
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
        composer_client: QualifiedSynthesisClient,
        composer_authorizer: fn _profile, _context ->
          flunk("composer must not run after the fan-out row fails")
        end,
        composer_context: %{timeout_ms: 10_000, max_output_tokens: 1_024},
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"

    assert result.failed_rows ==
             ["fov4-independent-architecture"] ++
               Enum.map(fixture["composition_cases"], & &1["id"])

    assert result.stats.adaptive_kind == "answer"
    assert result.stats.adaptive_child_count == 0
    assert result.stats.composition_valid == false
    assert result.stats.composition_rows_passed == 0

    assert result.stats.composition_failure_stage_by_row
           |> Map.values()
           |> Enum.uniq() == ["manager_admission"]

    assert result.stats.composition_failure_reason_by_row
           |> Map.values()
           |> Enum.uniq() == ["manager_row_failed"]
  end

  test "composer failures record only closed stage and reason evidence" do
    fixture = V13FanoutEval.load_fixture!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result =
      V13FanoutEval.run(fixture,
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: qualified_manager(fixture, self()),
        composer_client: SensitiveProviderFailureClient,
        composer_authorizer: fn _profile, _context -> :ok end,
        composer_context: %{timeout_ms: 10_000, max_output_tokens: 1_024},
        store: store,
        full_sha: @full_sha,
        dirty: true
      )

    assert result.status == "failed"
    assert result.stats.manager_rows_passed == 2
    assert result.stats.composition_rows_passed == 0

    assert result.stats.composition_failure_stage_by_row
           |> Map.values()
           |> Enum.uniq() == ["provider_call"]

    assert result.stats.composition_failure_reason_by_row
           |> Map.values()
           |> Enum.uniq() == ["provider_failed"]

    evidence = File.read!(store)
    assert evidence =~ "provider_call"
    assert evidence =~ "provider_failed"
    refute evidence =~ "sensitive provider body"
  end

  test "composer distinguishes unresolved review from finish failures without provider text" do
    fixture = V13FanoutEval.load_fixture!(@fixture)

    unresolved =
      run_composer_failure(
        fixture,
        {:error, {:invalid_model_output, :unresolved_fanout_report_synthesis}}
      )

    assert_closed_composer_failure(
      unresolved,
      "synthesis_review",
      "unresolved_fanout_report_synthesis"
    )

    incomplete =
      run_composer_failure(
        fixture,
        {:error,
         {:invalid_model_output, {:incomplete_composition_response, "sensitive finish detail"}}}
      )

    assert_closed_composer_failure(
      incomplete,
      "provider_output",
      "incomplete_composition_response"
    )

    refute inspect(incomplete.stats) =~ "sensitive finish detail"
  end

  test "composer keeps extraction schema layout review and body diagnostics distinct" do
    fixture = V13FanoutEval.load_fixture!(@fixture)

    cases = [
      {:empty_composition_selection, "provider_output", "empty_composition_selection"},
      {:invalid_synthesis_rule_evidence, "provider_output", "invalid_synthesis_rule_evidence"},
      {:invalid_fanout_report_synthesis_selection, "synthesis_schema",
       "invalid_fanout_report_synthesis_selection"},
      {:invalid_fanout_report_composition_section, "synthesis_layout",
       "invalid_fanout_report_composition_section"},
      {:invalid_fanout_report_synthesis_review, "synthesis_review",
       "invalid_fanout_report_synthesis_review"},
      {:fanout_report_synthesis_too_large, "synthesis_body", "fanout_report_synthesis_too_large"},
      {{:arbitrary_provider_reason, "private provider text"}, "provider_output",
       "invalid_model_output"}
    ]

    for {nested_reason, expected_stage, expected_reason} <- cases do
      result =
        run_composer_failure(fixture, {:error, {:invalid_model_output, nested_reason}})

      assert_closed_composer_failure(result, expected_stage, expected_reason)
      refute inspect(result.stats) =~ "private provider text"
      refute inspect(result.stats) =~ "arbitrary_provider_reason"
    end
  end

  test "manager/composer fixture digest binds the decoded frozen corpus" do
    fixture = @fixture |> File.read!() |> Jason.decode!()

    changed =
      update_in(
        fixture,
        ["composition_cases", Access.at(0), "snapshot", "children", Access.at(0), "detail"],
        fn detail -> detail <> " " end
      )

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

  defp run_composer_failure(fixture, failure_result) do
    V13FanoutEval.run(fixture,
      profile: @profile,
      manager_profile: @profile,
      composer_profile: @profile,
      manager: qualified_manager(fixture, self()),
      composer_client: ClassifiedFailureSynthesisClient,
      composer_authorizer: fn _profile, _context -> :ok end,
      composer_context: %{
        timeout_ms: 10_000,
        max_output_tokens: 1_024,
        failure_result: failure_result
      },
      store: :disabled,
      full_sha: @full_sha,
      dirty: true
    )
  end

  defp assert_closed_composer_failure(result, stage, reason) do
    assert result.status == "failed"
    assert result.stats.composition_rows_passed == 0
    assert result.stats.composition_failure_stage_by_row |> Map.values() |> Enum.uniq() == [stage]

    assert result.stats.composition_failure_reason_by_row |> Map.values() |> Enum.uniq() == [
             reason
           ]
  end

  defp phase_options(fixtures, opts) do
    store = Keyword.fetch!(opts, :store)

    [
      manager_and_composer: [
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: qualified_manager(fixtures.manager_and_composer, self()),
        composer_client: QualifiedSynthesisClient,
        composer_authorizer: fn _profile, _context -> :ok end,
        composer_context: %{
          timeout_ms: 10_000,
          max_output_tokens: 1_024,
          test_pid: self()
        },
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
