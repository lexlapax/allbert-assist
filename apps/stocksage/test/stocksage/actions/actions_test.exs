defmodule StockSage.ActionsTest do
  use StockSage.DataCase

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Skills
  alias AllbertAssist.Settings
  alias StockSage.{Analyses, Queue}

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
    for {name, permission} <- [
          {"list_analyses", :read_only},
          {"show_analysis", :read_only},
          {"get_trends", :read_only},
          {"queue_analysis", :stocksage_write}
        ] do
      assert {:ok, capability} = Registry.capability(name)
      assert capability.permission == permission
      assert capability.app_id == :stocksage
      assert capability.plugin_id == "stocksage"
      assert capability.execution_mode == :local_domain
      assert capability.exposure == :agent
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
    refute "run-analysis" in skill_names
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

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
