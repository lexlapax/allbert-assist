defmodule AllbertAssist.DevGates.V13FanoutEvalTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.DevGates.V13FanoutEval
  alias AllbertAssist.Intent.FanoutPlan
  alias AllbertAssist.Models.ProviderAttempt
  alias AllbertAssist.Settings

  @fixture Path.expand("../../fixtures/v1.3/fanout_real_model_eval.json", __DIR__)
  @fixture_sha256 "59c2b74ec85f004cea27ad0c5088eeb5f1ea98f3cf45dd3949524f41f6f93f99"
  @full_sha String.duplicate("a", 40)
  @profile %{
    name: "direct_answer_local",
    provider: "local_ollama",
    model: "qwen2.5:7b"
  }
  @role_profile_bindings Map.new(
                           Enum.with_index(~w[worker manager review synthesis]),
                           fn {role, index} ->
                             {role,
                              %{
                                profile: "direct_answer_local",
                                provider: "local_ollama",
                                model: "qwen2.5:7b",
                                endpoint_class: "local",
                                endpoint_sha256: String.duplicate("a", 64),
                                configuration_sha256:
                                  String.duplicate(Integer.to_string(index + 1), 64)
                              }}
                           end
                         )

  test "frozen mixed topology keeps Worker on 7B and binds every fan-out role to Mistral" do
    profiles =
      V13FanoutEval.configure_profiles!("direct_answer_local", mixed_mistral?: true)

    assert profiles.worker.name == "direct_answer_local"

    for role <- [:manager, :review, :synthesis] do
      profile = Map.fetch!(profiles, role)
      assert profile.name == "mistral_small31_24b_challenger"
      assert profile.provider == "local_ollama"
      assert profile.model == "mistral-small3.1:24b-instruct-2503-q4_K_M"
      assert profile.aliases == []
      assert profile.capabilities == ["text_generation"]
      assert profile.temperature == 0.0
      assert profile.max_tokens == 1_024
      assert profile.timeout_ms == 60_000
    end

    assert {:ok, ["direct_answer_local"]} =
             Settings.get("model_preferences.tasks.direct_answer")

    for task <- ~w[fanout_manager fanout_review fanout_synthesis] do
      assert {:ok, ["mistral_small31_24b_challenger"]} =
               Settings.get("model_preferences.tasks.#{task}")
    end

    assert Map.keys(profiles.bindings) |> Enum.sort() == ~w[manager review synthesis worker]

    for {_role, binding} <- profiles.bindings do
      assert Map.keys(binding) |> Enum.sort() ==
               ~w[configuration_sha256 endpoint_class endpoint_sha256 model profile provider]a

      assert byte_size(binding.endpoint_sha256) == 64
      assert byte_size(binding.configuration_sha256) == 64
    end
  end

  test "frozen mixed topology rejects a non-default Worker before settings writes" do
    before = Settings.get("model_preferences.tasks.direct_answer")

    assert_raise RuntimeError, ~r/mixed_mistral_requires_direct_answer_local/, fn ->
      V13FanoutEval.configure_profiles!("local", mixed_mistral?: true)
    end

    assert Settings.get("model_preferences.tasks.direct_answer") == before
  end

  defmodule QualifiedRevisionAnswerer do
    def answer(_prompt, context) do
      :ok = ProviderAttempt.mark(context)

      message =
        case context.quality_eval_case_id do
          "restart-inaccuracy-repaired" -> "Corrected restart strategy distinction."
          "replay-guarantee-overclaim-repaired" -> "Corrected replay guarantee distinction."
          "omitted-required-nuance-unresolved" -> "The required threshold remains unavailable."
        end

      {:ok, %{message: message, diagnostic: %{status: :used}}}
    end
  end

  setup do
    previous = Application.get_env(:allbert_assist, DirectAnswer)
    Application.put_env(:allbert_assist, DirectAnswer, answerer: QualifiedRevisionAnswerer)

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

  defmodule QualifiedSynthesisClient do
    def compose(snapshot, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:synthesis_client, snapshot})

      {:ok,
       %{
         sections: sections(snapshot.parent_id),
         advisory_synthesis:
           "The reviewed observations support the selected relationship while durable status and receipt truth remain authoritative in Allbert."
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
  end

  defmodule SensitiveProviderFailureClient do
    def compose(_snapshot, _profile, _context),
      do: {:error, {:provider_failed, "sensitive provider body must never enter metrics"}}
  end

  defmodule ForgedPhaseEvidenceSynthesisClient do
    alias AllbertAssist.DevGates.V13FanoutEvalTest.QualifiedSynthesisClient

    def compose(snapshot, profile, context) do
      {:ok, selection} =
        QualifiedSynthesisClient.compose(snapshot, profile, context)

      {:ok, Map.put(selection, :provider_call_count, 0)}
    end
  end

  defmodule ClassifiedFailureSynthesisClient do
    def compose(_snapshot, _profile, context), do: Map.fetch!(context, :failure_result)
  end

  test "focused qualification accepts seven single-call v3 syntheses through the lifecycle" do
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

    assert result.status == "passed", inspect(result, limit: :infinity)
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
             Map.take(row, [:generation_call_count, :provider_call_count]) == %{
               generation_call_count: 1,
               provider_call_count: 1
             }
           end)

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

    for {stat, row_key} <- [
          composition_generation_call_count_by_row: :generation_call_count,
          composition_provider_call_count_by_row: :provider_call_count
        ] do
      assert Map.fetch!(result.stats, stat) == Map.new(composition_rows, &{&1.id, &1[row_key]})
    end

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

    assert record["stats"]["composition_provider_call_count_by_row"] ==
             result.stats.composition_provider_call_count_by_row

    assert record["stats"]["composition_generation_call_count_by_row"] ==
             result.stats.composition_generation_call_count_by_row

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

  test "a fake composer result cannot forge passing phase evidence" do
    fixture = V13FanoutEval.load_fixture!(@fixture)

    result =
      V13FanoutEval.run(fixture,
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: qualified_manager(fixture, self()),
        composer_client: ForgedPhaseEvidenceSynthesisClient,
        composer_authorizer: fn _profile, _context -> :ok end,
        composer_context: %{
          timeout_ms: 10_000,
          max_output_tokens: 1_024,
          test_pid: self()
        },
        store: :disabled,
        full_sha: @full_sha,
        dirty: true
      )

    assert_closed_composer_failure(result, "provider_output", "invalid_model_output")

    assert result.stats.composition_provider_call_count_by_row |> Map.values() |> Enum.uniq() == [
             nil
           ]

    assert result.stats.composition_provider_call_count_by_row |> Map.values() |> Enum.uniq() ==
             [nil]
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

  test "public orchestration runs the single phase and stores content-free provenance" do
    fixtures = V13FanoutEval.load_fixtures!(@fixture)
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

    result = V13FanoutEval.run_phases(fixtures, phase_options(store))

    assert result.status == "passed", inspect(result, limit: :infinity)
    assert result.failed_rows == []
    assert result.manager_and_composer.status == "passed"

    assert [record] = read_store(store)
    assert record["phase_or_step"] == "manager-and-composer"
    assert record["command"] == "bench-v13-fanout --mixed-mistral"
    assert record["stats"]["fixture_sha256"] == @fixture_sha256

    assert record["stats"]["role_profile_bindings"] ==
             Jason.decode!(Jason.encode!(@role_profile_bindings))

    evidence = File.read!(store)
    assert evidence =~ @fixture_sha256
    refute evidence =~ Path.basename(@fixture)
    refute evidence =~ "archive logs"
    refute evidence =~ "one_for_one"
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

  defp phase_options(store) do
    [
      manager_and_composer: [
        profile: @profile,
        manager_profile: @profile,
        composer_profile: @profile,
        manager: qualified_manager(V13FanoutEval.load_fixture!(@fixture), self()),
        composer_client: QualifiedSynthesisClient,
        composer_authorizer: fn _profile, _context -> :ok end,
        composer_context: %{
          timeout_ms: 10_000,
          max_output_tokens: 1_024,
          test_pid: self()
        },
        role_profile_bindings: @role_profile_bindings,
        command: "bench-v13-fanout --mixed-mistral",
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
