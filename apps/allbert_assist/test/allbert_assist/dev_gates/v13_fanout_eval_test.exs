defmodule AllbertAssist.DevGates.V13FanoutEvalTest do
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.V13FanoutEval
  alias AllbertAssist.Intent.FanoutPlan

  @fixture Path.expand("../../fixtures/v1.3/fanout_real_model_eval.json", __DIR__)
  @full_sha String.duplicate("a", 40)
  @profile %{
    name: "direct_answer_local",
    provider: "local_ollama",
    model: "qwen2.5:7b"
  }

  test "focused qualification accepts structured manager and composer outcomes" do
    fixture = V13FanoutEval.load_fixture!(@fixture)
    parent = self()

    manager = fn text, context ->
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

    composer = fn snapshot, profile, context ->
      send(parent, {:composer, snapshot, profile, context})

      {:ok,
       %{
         sections: [
           %{relationship: "complementary", ordered_queue_positions: [0, 1]}
         ]
       }}
    end

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

  defp read_store(store) do
    store
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
