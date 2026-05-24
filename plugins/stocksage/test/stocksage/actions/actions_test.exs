defmodule StockSage.ActionsTest do
  use StockSage.DataCase

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Skills
  alias AllbertAssist.Settings
  alias StockSage.{Analyses, Queue}
  alias StockSage.LegacyFixture

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "stocksage-actions-settings-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)
    PluginRegistry.register_module(StockSage.Plugin)
    AppRegistry.register(StockSage.App)
    AllbertAssist.Objectives.Proposer.register_app_proposer(:stocksage, StockSage.Proposer)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "registered action capabilities carry StockSage app metadata" do
    for {name, permission, exposure} <- [
          {"list_analyses", :read_only, :agent},
          {"show_analysis", :read_only, :agent},
          {"get_trends", :read_only, :agent},
          {"resolve_outcomes", :stocksage_write, :internal},
          {"generate_reflection", :stocksage_write, :internal},
          {"queue_analysis", :stocksage_write, :agent},
          {"list_queue", :read_only, :internal},
          {"import_stocksage_sqlite", :stocksage_write, :internal}
        ] do
      assert {:ok, capability} = Registry.capability(name)
      assert capability.permission == permission
      assert capability.app_id == :stocksage
      assert capability.plugin_id == "stocksage"
      assert capability.execution_mode == :local_domain
      assert capability.exposure == exposure
    end
  end

  test "list and show actions return bounded user-scoped rows through the runner" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               status: "completed",
               source: "manual",
               summary: "AAPL summary"
             })

    assert {:ok, _detail} =
             Analyses.create_detail(%{
               user_id: "alice",
               analysis_id: analysis.id,
               section: "technical",
               content: "trend",
               payload: %{
                 "engine" => "tradingagents",
                 "stub" => false,
                 "truncated" => false,
                 "raw_vendor_payload" => "must not leave the action boundary"
               }
             })

    assert {:ok, _bob} =
             Analyses.create_analysis(%{
               user_id: "bob",
               symbol: "aapl",
               status: "completed",
               source: "manual"
             })

    assert {:ok, list_response} =
             Runner.run("list_analyses", %{user_id: "alice"}, stocksage_context())

    assert [%{id: analysis_id}] = list_response.analyses
    assert analysis_id == analysis.id
    assert list_response.runner_metadata.action_capability.app_id == :stocksage

    assert {:ok, show_response} =
             Runner.run(
               "show_analysis",
               %{user_id: "alice", analysis_id: analysis.id},
               stocksage_context()
             )

    assert show_response.analysis.id == analysis.id
    assert [%{section: "technical"} = detail] = show_response.analysis.details

    assert detail.payload == %{
             "engine" => "tradingagents",
             "stub" => false,
             "truncated" => false
           }

    refute Map.has_key?(detail.payload, "raw_vendor_payload")

    assert {:ok, missing_response} =
             Runner.run(
               "show_analysis",
               %{user_id: "bob", analysis_id: analysis.id},
               stocksage_context()
             )

    assert missing_response.status == :not_found
  end

  test "get_trends summarizes only local outcomes" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               status: "completed",
               source: "manual"
             })

    assert {:ok, _outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "aapl",
               label: "win",
               return_pct: Decimal.new("7.5")
             })

    assert {:ok, response} = Runner.run("get_trends", %{user_id: "alice"}, stocksage_context())

    assert response.status == :completed
    assert response.trends.counts == %{"win" => 1}
    assert response.trends.accuracy.resolved == 1
    assert response.trends.accuracy.win_rate == 100.0
    assert [%{rating: "unrated", wins: 1}] = response.trends.rating_calibration
    assert [%{symbol: "AAPL", wins: 1}] = response.trends.leaderboard
    assert [%{label: "win"}] = response.trends.outcomes
  end

  test "resolve_outcomes resolves due local outcomes through the runner" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               analysis_date: ~D[2026-05-01],
               status: "completed",
               source: "manual",
               recommendation: "Buy"
             })

    assert {:ok, _outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "aapl",
               horizon_days: 5,
               start_price: Decimal.new("100.00"),
               label: "pending"
             })

    assert {:ok, response} =
             Runner.run(
               "resolve_outcomes",
               %{user_id: "alice", as_of: "2026-05-10", prices: %{"AAPL" => "105.25"}},
               stocksage_context()
             )

    assert response.status == :completed
    assert response.outcome_resolution.resolved == 1
    assert [%{label: "win"}] = response.outcome_resolution.outcomes

    assert [updated] = Analyses.list_outcomes_for_analysis("alice", analysis.id)
    assert updated.label == "win"
  end

  test "generate_reflection writes a StockSage-local reflection through the runner" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               status: "completed",
               source: "manual",
               recommendation: "Buy"
             })

    assert {:ok, outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "aapl",
               label: "win",
               horizon_days: 30,
               return_pct: Decimal.new("8.0")
             })

    assert {:ok, response} =
             Runner.run(
               "generate_reflection",
               %{user_id: "alice", outcome_id: outcome.id},
               stocksage_context()
             )

    assert response.status == :completed
    assert response.reflection.outcome_id == outcome.id
    assert response.reflection.promoted_to_allbert_memory == false
  end

  test "queue_analysis writes one local queue row and starts no execution worker" do
    assert {:ok, response} =
             Runner.run(
               "queue_analysis",
               %{
                 user_id: "alice",
                 symbol: " tsla ",
                 thread_id: "thread_1",
                 objective_id: "obj_queue_test",
                 step_id: "step_queue_test"
               },
               stocksage_context(%{session_id: "session_1"})
             )

    assert response.status == :completed
    assert response.queue_entry.symbol == "TSLA"
    assert response.queue_entry.objective_id == "obj_queue_test"
    assert response.queue_entry.step_id == "step_queue_test"

    assert [%{symbol: "TSLA", status: "queued", objective_id: "obj_queue_test"}] =
             Queue.list_entries("alice")
  end

  test "actions require explicit user context at the action boundary" do
    assert {:ok, response} = Runner.run("queue_analysis", %{symbol: "AAPL"}, stocksage_context())

    assert response.status == :error
    assert response.error == :missing_user_id
    assert [] = Queue.list_entries("local")
  end

  test "list_queue reads rows through the runner" do
    assert {:ok, entry} = Queue.create_entry(%{user_id: "alice", symbol: "aapl"})

    assert {:ok, response} = Runner.run("list_queue", %{user_id: "alice"}, stocksage_context())

    assert response.status == :completed
    assert [%{id: id, symbol: "AAPL"}] = response.queue_entries
    assert id == entry.id
  end

  test "import_stocksage_sqlite imports only after runner authorization" do
    path =
      Path.join(
        System.tmp_dir!(),
        "stocksage-action-fixture-#{System.unique_integer([:positive])}.db"
      )

    LegacyFixture.create!(path)
    on_exit(fn -> File.rm(path) end)

    assert {:ok, response} =
             Runner.run(
               "import_stocksage_sqlite",
               %{user_id: "alice", path: path, dry_run: true},
               stocksage_context()
             )

    assert response.status == :completed
    assert response.import.dry_run
    assert response.import.counts["analyses"].inserted == 3
    assert [] = Analyses.list_analyses("alice")

    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "permissions" => %{"stocksage_write" => "denied"}
             })

    assert {:ok, denied} =
             Runner.run(
               "import_stocksage_sqlite",
               %{user_id: "alice", path: path},
               stocksage_context()
             )

    assert denied.status == :denied
    assert [] = Analyses.list_analyses("alice")
  end

  test "stocksage_write can be denied without affecting read-only actions" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "permissions" => %{"stocksage_write" => "denied"}
             })

    assert {:ok, denied} =
             Runner.run(
               "queue_analysis",
               %{user_id: "alice", symbol: "AAPL"},
               stocksage_context()
             )

    assert denied.status == :denied
    assert [] = Queue.list_entries("alice")

    assert {:ok, allowed} =
             Runner.run("list_analyses", %{user_id: "alice"}, stocksage_context())

    assert allowed.status == :completed
  end

  test "skills are discovered from the StockSage plugin root" do
    assert {:ok, skills} = Skills.list(%{})

    skill_names = Enum.map(skills, & &1.name)

    assert "queue-analysis" in skill_names
    assert "list-analyses" in skill_names
    assert "show-analysis" in skill_names
    assert "get-trends" in skill_names
    assert "run-analysis" in skill_names
  end

  test "active StockSage app context produces StockSage action candidates" do
    assert {:ok, decision} =
             Engine.decide(%{
               text: "list my recent analyses",
               user_id: "alice",
               active_app: :stocksage
             })

    selected = decision.trace_metadata.intent_candidates.selected

    assert selected.kind == :action
    assert selected.app_id == :stocksage
    assert selected.action_name in ["list_analyses", "show_analysis"]
  end

  test "RunAnalysis appears as a candidate when active_app is stocksage" do
    assert {:ok, decision} =
             Engine.decide(%{
               text: "analyze AAPL for 2026-05-01",
               user_id: "alice",
               active_app: :stocksage
             })

    %{selected: selected, rejected: rejected} = decision.trace_metadata.intent_candidates
    all = [selected | rejected]

    assert Enum.any?(all, fn candidate ->
             Map.get(candidate, :action_name) == "run_analysis"
           end),
           "run_analysis not in candidates: #{inspect(Enum.map(all, &Map.get(&1, :action_name)))}"
  end

  # v0.33 keeps the v0.22 active-app selection invariant, but the recognition
  # now comes from StockSage's intent descriptor instead of a core StockSage
  # keyword branch.
  test "Engine.decide selects run_analysis for analyze + active_app stocksage" do
    assert {:ok, decision} =
             Engine.decide(%{
               text: "analyze AAPL for 2026-05-01",
               user_id: "alice",
               active_app: :stocksage
             })

    assert decision.selected_action == "run_analysis",
           "expected selected_action=run_analysis, got #{inspect(decision.selected_action)}; " <>
             "intent=#{inspect(decision.intent)}; " <>
             "selected=#{inspect(decision.trace_metadata.intent_candidates.selected)}"

    assert decision.trace_metadata.candidate_kind == :app_intent
    assert decision.trace_metadata.descriptor_candidate_id == "stocksage:run_analysis"
  end

  test "Engine.decide selects get_trends descriptor with optional symbol in StockSage context" do
    assert {:ok, decision} =
             Engine.decide(%{
               text: "show trends for AAPL",
               user_id: "alice",
               active_app: :stocksage
             })

    assert decision.selected_action == "get_trends"
    assert decision.trace_metadata.candidate_kind == :app_intent
    assert decision.trace_metadata.descriptor_candidate_id == "stocksage:get_trends"
    assert decision.trace_metadata.extracted_slots == %{symbol: "AAPL"}
  end

  test "Engine.decide selects queue_analysis descriptor in StockSage context" do
    assert {:ok, decision} =
             Engine.decide(%{
               text: "queue analysis for AAPL",
               user_id: "alice",
               active_app: :stocksage
             })

    assert decision.selected_action == "queue_analysis"
    assert decision.trace_metadata.candidate_kind == :app_intent
    assert decision.trace_metadata.descriptor_candidate_id == "stocksage:queue_analysis"
    assert decision.trace_metadata.extracted_slots == %{symbol: "AAPL"}
  end

  test "Engine.decide does NOT select run_analysis when active_app is not stocksage" do
    # Cross-app routing must remain explicit. Without the StockSage session
    # the active-app boost does not apply and the engine falls back to its
    # default (direct_answer) for the same phrasing.
    assert {:ok, decision} =
             Engine.decide(%{
               text: "analyze AAPL for 2026-05-01",
               user_id: "alice"
             })

    refute decision.selected_action == "run_analysis",
           "run_analysis should not be selected without active_app: :stocksage; " <>
             "got selected_action=#{inspect(decision.selected_action)}"
  end

  test "intent agent uses descriptor params for active StockSage trends" do
    assert {:ok, aapl_analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               status: "completed",
               source: "manual"
             })

    assert {:ok, _aapl_outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: aapl_analysis.id,
               symbol: "aapl",
               label: "win",
               return_pct: Decimal.new("7.5")
             })

    assert {:ok, msft_analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "msft",
               status: "completed",
               source: "manual"
             })

    assert {:ok, _msft_outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: msft_analysis.id,
               symbol: "msft",
               label: "loss",
               return_pct: Decimal.new("-2.0")
             })

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "show trends for AAPL",
               user_id: "alice",
               active_app: :stocksage
             })

    assert response.status == :completed
    assert response.decision.selected_action == "get_trends"
    assert response.decision.trace_metadata.extracted_slots == %{symbol: "AAPL"}
    assert [%{name: "get_trends", status: :completed}] = response.actions
    assert [%{symbol: "AAPL"}] = response.trends.leaderboard
    assert [%{symbol: "AAPL"}] = response.trends.outcomes
  end

  test "intent agent uses descriptor params for active StockSage queue writes" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "queue analysis for AAPL",
               user_id: "alice",
               active_app: :stocksage,
               thread_id: "thr-queue-descriptor",
               session_id: "sess-queue-descriptor"
             })

    assert response.status == :completed
    assert response.decision.selected_action == "queue_analysis"
    assert response.decision.trace_metadata.extracted_slots == %{symbol: "AAPL"}
    assert [%{name: "queue_analysis", status: :completed}] = response.actions
    assert [%{symbol: "AAPL", thread_id: "thr-queue-descriptor"}] = Queue.list_entries("alice")
  end

  test "neutral queue descriptor handoff creates no queue row" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "queue analysis for AAPL",
               user_id: "alice",
               active_app: :allbert,
               thread_id: "thr-neutral-queue-handoff",
               session_id: "sess-neutral-queue-handoff"
             })

    assert response.status == :completed
    assert response.decision.intent == :app_handoff
    assert response.intent_handoff.action_name == "queue_analysis"
    assert response.intent_handoff.extracted_slots == %{"symbol" => "AAPL"}
    refute Enum.any?(response.actions, &Map.has_key?(&1, :confirmation_id))
    assert [] = Queue.list_entries("alice")
  end

  test "neutral queue descriptor missing symbol asks for clarification" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "queue analysis",
               user_id: "alice",
               active_app: :allbert,
               thread_id: "thr-neutral-queue-clarify",
               session_id: "sess-neutral-queue-clarify"
             })

    assert response.status == :completed
    assert response.decision.intent == :clarify_intent
    assert response.intent_handoff.action_name == "queue_analysis"
    assert response.intent_handoff.missing_slots == ["symbol"]
    assert [] = Queue.list_entries("alice")
  end

  test "intent agent executes a selected StockSage action from active app context" do
    assert {:ok, _analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               status: "completed",
               source: "manual",
               summary: "AAPL summary"
             })

    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "list my analyses",
               user_id: "alice",
               active_app: :stocksage
             })

    assert response.status == :completed
    assert response.message == "Found 1 StockSage analyses for alice."
    assert response.active_app == :stocksage
    assert [%{name: "list_analyses", status: :completed}] = response.actions
    assert response.decision.selected_action == "list_analyses"
  end

  test "intent agent starts a StockSage objective and objective-bound confirmation" do
    assert {:ok, response} =
             IntentAgent.respond(%{
               text: "analyze AAPL",
               user_id: "alice",
               active_app: :stocksage
             })

    assert response.decision.selected_action == "run_analysis"
    assert response.status == :needs_confirmation
    assert is_binary(response.confirmation_id)
    assert response.objective.title == "Analyze AAPL"
    assert response.objective.step_count == 1
    assert Enum.any?(response.actions, &match?(%{name: "frame_objective"}, &1))

    [objective] = AllbertAssist.Objectives.list_objectives("alice", active_app: "stocksage")
    assert objective.title == "Analyze AAPL"
    assert objective.status == "blocked"

    assert [step] = AllbertAssist.Objectives.list_steps(objective.id)
    assert step.status == "blocked"
    assert step.confirmation_id == response.confirmation_id
    assert step.candidate_action == "StockSage.Actions.RunAnalysis"
    assert step.action_params |> Jason.decode!() |> Map.fetch!("ticker") == "AAPL"

    {:ok, confirmation} = AllbertAssist.Confirmations.read(response.confirmation_id)
    assert confirmation["objective_id"] == objective.id
    assert confirmation["step_id"] == step.id
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp stocksage_context(attrs \\ %{}), do: Map.merge(%{active_app: :stocksage}, attrs)
end
