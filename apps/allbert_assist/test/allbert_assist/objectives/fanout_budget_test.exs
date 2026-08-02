defmodule AllbertAssist.Objectives.Fanout.BudgetTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.FanoutManager
  alias AllbertAssist.Objectives.Fanout.Budget
  alias AllbertAssist.Objectives.Fanout.PlanProvenance
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments

  defmodule InvalidManagerModel do
    alias AllbertAssist.Models.ProviderAttempt

    def respond(_text, _profile, context) do
      :ok = ProviderAttempt.mark(context)
      send(context.test_pid, {:manager_attempt, context.fanout_manager_attempt})

      case context.fanout_manager_attempt do
        :initial ->
          {:ok,
           %{
             "mode" => "fanout",
             "answer" => "I can answer this safely as one request.",
             "children_json" => "[]"
           }}

        {:repair, _reason} ->
          {:error, :unexpected_repair}
      end
    end
  end

  @profile %{
    name: "local",
    provider: "local_ollama",
    provider_endpoint_kind: "local_endpoint",
    provider_type: "openai_compatible",
    model: "fixture-model",
    max_tokens: 8_192,
    timeout_ms: 5_000
  }

  @request "Research alpha and beta independently, then report the findings."

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-fanout-budget-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)

    on_exit(fn ->
      restore_env(Paths, original_paths)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "resolves one bounded JSON-safe structural budget from Settings Central defaults" do
    assert {:ok, snapshot} = Budget.resolve(8, 2)

    assert snapshot == %{
             "version" => 2,
             "child_count" => 8,
             "manager_attempts" => 2,
             "worker_attempts_per_child" => 2,
             "configured_model_calls" => 64,
             "required_model_calls" => 56,
             "configured_output_tokens" => 32_768,
             "required_output_tokens" => 30_720,
             "max_elapsed_ms" => 300_000
           }

    assert snapshot == snapshot |> Jason.encode!() |> Jason.decode!()
  end

  test "refuses a plan whose structural call requirement exceeds its configured limit" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.max_model_calls_per_plan", 55, %{audit?: false})

    assert {:error,
            {:fanout_budget_exhausted,
             %{
               "budget" => "model_calls",
               "configured" => 55,
               "required" => 56
             }}} = Budget.resolve(8, 2)
  end

  test "refuses a plan whose structural output-token requirement exceeds its configured limit" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.max_output_tokens_per_plan", 30_719, %{
               audit?: false
             })

    assert {:error,
            {:fanout_budget_exhausted,
             %{
               "budget" => "output_tokens",
               "configured" => 30_719,
               "required" => 30_720
             }}} = Budget.resolve(8, 2)
  end

  test "rejects child and manager counts outside the structural plan bounds" do
    for invalid <- [1, 17, "8", nil] do
      assert {:error, {:invalid_fanout_budget_input, "child_count", ^invalid}} =
               Budget.resolve(invalid, 1)
    end

    for invalid <- [-1, 3, "1", nil] do
      assert {:error, {:invalid_fanout_budget_input, "manager_attempts", ^invalid}} =
               Budget.resolve(2, invalid)
    end
  end

  test "freezes limits before manager work and resolves the later plan from that snapshot" do
    assert {:ok, limits} = Budget.limits()

    assert limits == %{
             version: 2,
             max_model_calls: 64,
             max_output_tokens: 32_768,
             max_elapsed_ms: 300_000,
             max_worker_attempts_per_child: 2
           }

    assert limits.max_elapsed_ms == 300_000

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.max_model_calls_per_plan", 5, %{audit?: false})

    assert {:ok, %{"configured_model_calls" => 64}} = Budget.resolve(2, 0, limits)

    assert {:error,
            {:fanout_budget_exhausted,
             %{"budget" => "model_calls", "configured" => 5, "required" => 18}}} =
             Budget.resolve(2, 0)
  end

  test "Settings Central owns writable defaults and bounded validation for every plan limit" do
    cases = [
      {"objectives.fanout.max_model_calls_per_plan", 64, 1, 256},
      {"objectives.fanout.max_output_tokens_per_plan", 32_768, 1_024, 1_000_000},
      {"objectives.fanout.max_elapsed_ms_per_plan", 300_000, 1_000, 3_600_000},
      {"objectives.fanout.max_worker_attempts_per_child", 2, 1, 4}
    ]

    for {key, default, minimum, maximum} <- cases do
      assert {:ok, ^default} = Settings.get(key)
      assert Settings.safe_write_key?(key)
      assert {:ok, %{id: "core:objectives"}} = Fragments.fragment_for_key(key)

      assert {:ok, %{value: ^minimum}} = Settings.put(key, minimum, %{audit?: false})

      assert {:error, {:invalid_setting, ^key, _reason}} =
               Settings.put(key, minimum - 1, %{audit?: false})

      assert {:ok, %{value: ^maximum}} = Settings.put(key, maximum, %{audit?: false})

      assert {:error, {:invalid_setting, ^key, _reason}} =
               Settings.put(key, maximum + 1, %{audit?: false})
    end
  end

  test "rejects forged or out-of-range frozen limits" do
    assert {:ok, limits} = Budget.limits()

    assert {:error, {:invalid_fanout_budget_limits, "snapshot", _limits}} =
             Budget.resolve(2, 0, %{limits | version: 1})

    assert {:error, {:invalid_fanout_budget_limits, "max_elapsed_ms", 999}} =
             Budget.resolve(2, 0, %{limits | max_elapsed_ms: 999})
  end

  test "worker window enforces the frozen retry count and durable plan deadline" do
    assert {:ok, snapshot} = Budget.resolve(2, 1)
    now_ms = 1_000_000

    assert :ok = Budget.authorize_worker(snapshot, 1, now_ms + 10_000, now_ms)
    assert :ok = Budget.authorize_worker(snapshot, 2, now_ms + 10_000, now_ms)

    assert {:error, :fanout_worker_attempt_budget_exhausted} =
             Budget.authorize_worker(snapshot, 3, now_ms + 10_000, now_ms)

    assert {:error, :fanout_plan_deadline_exhausted} =
             Budget.authorize_worker(snapshot, 1, now_ms, now_ms)

    assert {:error, :invalid_fanout_budget_snapshot} =
             Budget.authorize_worker(%{"version" => 2}, 1, now_ms + 10_000, now_ms)
  end

  test "historical Budget-v1 snapshots replay and authorize only safe worker recovery" do
    historical = %{
      "version" => 1,
      "child_count" => 2,
      "manager_attempts" => 1,
      "worker_attempts_per_child" => 2,
      "configured_model_calls" => 40,
      "required_model_calls" => 10,
      "configured_output_tokens" => 24_000,
      "required_output_tokens" => 6_144,
      "max_elapsed_ms" => 300_000
    }

    assert {:ok, ^historical} = Budget.validate_snapshot(historical)

    assert :ok = Budget.authorize_worker(historical, 1, 1_010_000, 1_000_000)

    assert {:error, :review_protocol_upgrade_required} =
             Budget.authorize_composer(historical, 1_010_000, 1_000_000)

    assert {:error, :review_protocol_upgrade_required} =
             Budget.composer_compatibility(historical)
  end

  test "composer authorization returns the bounded six-call protocol inside the deadline" do
    assert {:ok, snapshot} = Budget.resolve(2, 1)
    now_ms = 1_000_000

    assert {:ok, %{max_calls: 6, max_output_tokens: 1_024, timeout_ms: 10_000}} =
             Budget.authorize_composer(snapshot, now_ms + 10_000, now_ms)

    assert {:error, :fanout_plan_deadline_exhausted} =
             Budget.authorize_composer(snapshot, now_ms, now_ms)

    assert {:error, :invalid_fanout_budget_snapshot} =
             Budget.authorize_composer(
               Map.delete(snapshot, "required_output_tokens"),
               now_ms + 1,
               now_ms
             )
  end

  test "closed plan provenance round-trips one canonical typed parent and proposal event" do
    plan = valid_plan()

    assert {:ok, encoded_hint} = PlanProvenance.encode_parent_hint(plan)
    assert {:ok, ^plan} = PlanProvenance.decode_parent_hint(encoded_hint)

    assert %{"fanout_plan" => %{"budget" => persisted_budget}} = Jason.decode!(encoded_hint)
    assert persisted_budget["configured_output_tokens"] == 32_768
    assert persisted_budget["required_output_tokens"] == 11_264

    child_ids = ["child-0", "child-1"]

    assert {:ok, encoded_event} = PlanProvenance.encode_proposal_event(plan, child_ids)
    assert {:ok, event} = PlanProvenance.decode_proposal_event(encoded_event)
    assert event["child_ids"] == child_ids
    assert event["child_count"] == 2
    assert event["budget"] == plan["budget"]
    assert event["plan_sha256"] == plan["plan_sha256"]

    assert {:ok, ^plan} =
             PlanProvenance.verify_binding(encoded_hint, encoded_event, child_ids)

    tampered_event = put_in(event, ["budget", "configured_model_calls"], 65)

    assert {:error, :invalid_fanout_plan_provenance} =
             PlanProvenance.verify_binding(encoded_hint, tampered_event, child_ids)
  end

  test "closed plan provenance rejects extra, missing, coerced, corrupt, and inconsistent fields" do
    plan = valid_plan()
    budget = plan["budget"]

    invalid_plans = [
      Map.put(plan, "extra", "not-allowed"),
      Map.delete(plan, "budget"),
      put_in(plan, ["budget", "configured_output_tokens"], "24000"),
      put_in(plan, ["budget", "configured_output_tokens"], -1),
      put_in(plan, ["budget", "configured_output_tokens"], "[REDACTED]"),
      put_in(plan, ["budget", "required_output_tokens"], budget["required_output_tokens"] + 1),
      put_in(plan, ["budget", "version"], 1),
      Map.put(plan, "version", 2),
      Map.put(plan, "manager_attempts", 2)
    ]

    for invalid <- invalid_plans do
      assert {:error, :invalid_fanout_plan_provenance} =
               PlanProvenance.decode_parent_hint(%{"fanout_plan" => invalid})

      assert {:error, :invalid_fanout_plan_provenance} =
               PlanProvenance.encode_parent_hint(invalid)
    end

    assert {:error, :invalid_fanout_plan_provenance} =
             PlanProvenance.decode_parent_hint(%{"fanout_plan" => plan, "extra" => true})

    assert {:error, :invalid_fanout_plan_provenance} =
             PlanProvenance.encode_proposal_event(plan, ["duplicate", "duplicate"])

    assert {:error, :invalid_fanout_plan_provenance} =
             PlanProvenance.encode_proposal_event(plan, ["only-one"])
  end

  test "manager repair is not called when the frozen call limit only covers the initial call" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.max_model_calls_per_plan", 1, %{audit?: false})

    assert {:ok,
            %{
              kind: :answer,
              message: "I can answer this safely as one request.",
              diagnostic: %{
                attempts: 1,
                repair_error:
                  {:fanout_budget_exhausted,
                   %{"budget" => "model_calls", "configured" => 1, "required" => 2}}
              }
            }} = FanoutManager.respond(@request, manager_context())

    assert_received {:manager_attempt, :initial}
    refute_received {:manager_attempt, {:repair, _reason}}
  end

  test "manager repair is not called when the frozen output limit only covers one response" do
    assert {:ok, _setting} =
             Settings.put("objectives.fanout.max_model_calls_per_plan", 2, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("objectives.fanout.max_output_tokens_per_plan", 1_024, %{audit?: false})

    assert {:ok,
            %{
              kind: :answer,
              diagnostic: %{
                attempts: 1,
                repair_error:
                  {:fanout_budget_exhausted,
                   %{"budget" => "output_tokens", "configured" => 1_024, "required" => 2_048}}
              }
            }} = FanoutManager.respond(@request, manager_context())

    assert_received {:manager_attempt, :initial}
    refute_received {:manager_attempt, {:repair, _reason}}
  end

  test "manager-attempt authorization enforces both frozen cumulative limits" do
    assert {:ok, limits} = Budget.limits()

    assert :ok = Budget.authorize_manager_attempt(limits, 1)
    assert :ok = Budget.authorize_manager_attempt(limits, 2)

    assert {:error,
            {:fanout_budget_exhausted,
             %{"budget" => "model_calls", "configured" => 1, "required" => 2}}} =
             Budget.authorize_manager_attempt(%{limits | max_model_calls: 1}, 2)

    assert {:error,
            {:fanout_budget_exhausted,
             %{"budget" => "output_tokens", "configured" => 1_024, "required" => 2_048}}} =
             Budget.authorize_manager_attempt(%{limits | max_output_tokens: 1_024}, 2)
  end

  defp manager_context do
    %{
      model_enabled?: true,
      model_profile: @profile,
      model_client: InvalidManagerModel,
      test_pid: self(),
      max_children_per_fanout: 8
    }
  end

  defp valid_plan do
    {:ok, budget} = Budget.resolve(2, 1)

    %{
      "version" => 1,
      "source" => "conversation_manager",
      "original_request_sha256" => String.duplicate("a", 64),
      "plan_sha256" => String.duplicate("b", 64),
      "manager_profile" => "direct_answer_local",
      "manager_profile_sha256" => String.duplicate("c", 64),
      "manager_attempts" => 1,
      "budget" => budget,
      "deadline_unix_ms" => System.system_time(:millisecond) + 300_000
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
