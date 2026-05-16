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
               content: "trend"
             })

    assert {:ok, _bob} =
             Analyses.create_analysis(%{
               user_id: "bob",
               symbol: "aapl",
               status: "completed",
               source: "manual"
             })

    assert {:ok, list_response} = Runner.run("list_analyses", %{user_id: "alice"}, %{})
    assert [%{id: analysis_id}] = list_response.analyses
    assert analysis_id == analysis.id
    assert list_response.runner_metadata.action_capability.app_id == :stocksage

    assert {:ok, show_response} =
             Runner.run("show_analysis", %{user_id: "alice", analysis_id: analysis.id}, %{})

    assert show_response.analysis.id == analysis.id
    assert [%{section: "technical"}] = show_response.analysis.details

    assert {:ok, missing_response} =
             Runner.run("show_analysis", %{user_id: "bob", analysis_id: analysis.id}, %{})

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
               label: "win"
             })

    assert {:ok, response} = Runner.run("get_trends", %{user_id: "alice"}, %{})

    assert response.status == :completed
    assert response.trends.counts == %{"win" => 1}
    assert [%{label: "win"}] = response.trends.outcomes
  end

  test "queue_analysis writes one local queue row and starts no execution worker" do
    assert {:ok, response} =
             Runner.run(
               "queue_analysis",
               %{user_id: "alice", symbol: " tsla ", thread_id: "thread_1"},
               %{session_id: "session_1"}
             )

    assert response.status == :completed
    assert response.queue_entry.symbol == "TSLA"
    assert [%{symbol: "TSLA", status: "queued"}] = Queue.list_entries("alice")
  end

  test "actions require explicit user context at the action boundary" do
    assert {:ok, response} = Runner.run("queue_analysis", %{symbol: "AAPL"}, %{})

    assert response.status == :error
    assert response.error == :missing_user_id
    assert [] = Queue.list_entries("local")
  end

  test "list_queue reads rows through the runner" do
    assert {:ok, entry} = Queue.create_entry(%{user_id: "alice", symbol: "aapl"})

    assert {:ok, response} = Runner.run("list_queue", %{user_id: "alice"}, %{})

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
               %{}
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
             Runner.run("import_stocksage_sqlite", %{user_id: "alice", path: path}, %{})

    assert denied.status == :denied
    assert [] = Analyses.list_analyses("alice")
  end

  test "stocksage_write can be denied without affecting read-only actions" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "permissions" => %{"stocksage_write" => "denied"}
             })

    assert {:ok, denied} = Runner.run("queue_analysis", %{user_id: "alice", symbol: "AAPL"}, %{})
    assert denied.status == :denied
    assert [] = Queue.list_entries("alice")

    assert {:ok, allowed} = Runner.run("list_analyses", %{user_id: "alice"}, %{})
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
           "run_analysis not in candidates: #{inspect(Enum.map(all, & &1.action_name))}"
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
