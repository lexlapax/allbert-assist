defmodule StockSage.PluginTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.App.Bootstrap, as: AppBootstrap
  alias AllbertAssist.App.Validator, as: AppValidator
  alias AllbertAssist.Plugin.Bootstrap, as: PluginBootstrap
  alias AllbertAssist.Plugin.ChildSupervisor
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Surface

  setup do
    plugin_registry = :"stocksage_plugin_registry_#{System.unique_integer([:positive])}"
    plugin_table = :"stocksage_plugin_table_#{System.unique_integer([:positive])}"
    child_supervisor = :"stocksage_child_supervisor_#{System.unique_integer([:positive])}"

    app_registry = :"stocksage_app_registry_#{System.unique_integer([:positive])}"
    app_table = :"stocksage_app_table_#{System.unique_integer([:positive])}"
    app_supervisor = :"stocksage_app_supervisor_#{System.unique_integer([:positive])}"

    start_supervised!({PluginRegistry, name: plugin_registry, table_name: plugin_table})
    start_supervised!({ChildSupervisor, name: child_supervisor})
    start_supervised!({DynamicSupervisor, name: app_supervisor, strategy: :one_for_one})

    start_supervised!(
      {AppRegistry, name: app_registry, table_name: app_table, dynamic_supervisor: app_supervisor}
    )

    %{
      plugin_registry: plugin_registry,
      child_supervisor: child_supervisor,
      app_registry: app_registry
    }
  end

  test "plugin contract contributes StockSage app and skill root" do
    assert StockSage.Plugin.plugin_id() == "stocksage"
    assert StockSage.Plugin.apps() == [StockSage.App]
    assert [skill_root] = StockSage.Plugin.skill_paths()
    assert String.ends_with?(skill_root, "plugins/stocksage/skills")

    assert StockSage.Plugin.actions() == [
             StockSage.Actions.ListAnalyses,
             StockSage.Actions.ShowAnalysis,
             StockSage.Actions.GetTrends,
             StockSage.Actions.ResolveOutcomes,
             StockSage.Actions.GenerateReflection,
             StockSage.Actions.QueueAnalysis,
             StockSage.Actions.ListQueue,
             StockSage.Actions.ImportSqlite,
             StockSage.Actions.RunAnalysis,
             StockSage.Actions.Agents.ListAgents,
             StockSage.Actions.Agents.ShowAgent,
             StockSage.Actions.Evidence.FetchMarketData,
             StockSage.Actions.Evidence.FetchNews,
             StockSage.Actions.Evidence.FetchSentiment,
             StockSage.Actions.Evidence.FetchFundamentals,
             StockSage.Actions.Evidence.FetchFinancials
           ]

    # child_spec/1 now returns the supervisor's full child_spec map (not the
    # {module, args} shorthand) so it satisfies the AllbertAssist.Plugin
    # @callback typespec. Dialyzer flagged the shorthand before v0.22 audit
    # closeout's pre-existing-warning cleanup.
    child_spec = StockSage.Plugin.child_spec([])
    assert is_map(child_spec)
    assert child_spec.id == StockSage.Supervisor
    assert {StockSage.Supervisor, :start_link, [_opts]} = child_spec.start
    assert child_spec.type == :supervisor
  end

  test "discovery finds StockSage as a shipped source-tree plugin" do
    discoveries =
      Discovery.discover(
        project_root: repo_root(),
        settings: %{
          "enabled" => [],
          "disabled" => [],
          "scan_paths" => ["./plugins"],
          "trusted_project_roots" => [],
          "load_policy" => "shipped_and_skill_only"
        }
      )

    assert {:module, StockSage.Plugin, _opts} =
             Enum.find(discoveries, &match?({:module, StockSage.Plugin, _opts}, &1))
  end

  test "bootstrap registers the plugin and app", %{
    plugin_registry: plugin_registry,
    child_supervisor: child_supervisor,
    app_registry: app_registry
  } do
    start_supervised!(
      {PluginBootstrap,
       name: :"stocksage_plugin_bootstrap_#{System.unique_integer([:positive])}",
       registry: plugin_registry,
       child_supervisor: child_supervisor,
       discoveries: [{:module, StockSage.Plugin, [source: :shipped]}]}
    )

    assert_eventually(fn ->
      assert [%{plugin_id: "stocksage"}] =
               PluginRegistry.registered_plugins(server: plugin_registry)

      assert %{active: active} = DynamicSupervisor.count_children(child_supervisor)
      assert active in [0, 1]
    end)

    assert {:ok, :stocksage} = AppRegistry.register(StockSage.App, server: app_registry)
    assert {:ok, entry} = AppRegistry.lookup(:stocksage, server: app_registry)
    assert entry.module == StockSage.App

    assert [%{namespace: :stocksage, writable: true}] =
             AppRegistry.registered_memory_namespaces(server: app_registry)

    assert {:ok, :stocksage} = AppRegistry.normalize_app_id("stocksage", server: app_registry)
    assert {:ok, :stocksage} = AppRegistry.normalize_app_id(:stocksage, server: app_registry)
  end

  test "app bootstrap consumes registered plugin apps", %{
    plugin_registry: plugin_registry,
    child_supervisor: child_supervisor,
    app_registry: app_registry
  } do
    start_supervised!(
      {PluginBootstrap,
       name: :"stocksage_plugin_bootstrap_#{System.unique_integer([:positive])}",
       registry: plugin_registry,
       child_supervisor: child_supervisor,
       discoveries: [{:module, StockSage.Plugin, [source: :shipped]}]}
    )

    start_supervised!(
      {AppBootstrap,
       name: :"stocksage_app_bootstrap_#{System.unique_integer([:positive])}",
       registry: app_registry,
       plugin_registry: plugin_registry}
    )

    assert_eventually(fn ->
      assert {:ok, entry} = AppRegistry.lookup(:stocksage, server: app_registry)
      assert entry.module == StockSage.App
    end)
  end

  test "StockSage app validates against the v0.18 surface provider contract" do
    assert :ok = StockSage.App.validate([])
    assert {:ok, attrs} = AppValidator.validate(StockSage.App)
    assert attrs.app_id == :stocksage

    assert attrs.memory_namespace == %{
             app_id: :stocksage,
             namespace: :stocksage,
             writable: true,
             description:
               "StockSage-owned analysis memory namespace; v0.29 writes require explicit lesson sync confirmation."
           }

    refute Code.ensure_loaded?(StockSage.Actions.SyncAppLesson)
    assert Code.ensure_loaded?(AllbertAssist.Actions.Memory.SyncAppLesson)

    assert attrs.provider_surfaces == StockSage.App.surfaces()
    assert attrs.surfaces == []

    assert Enum.map(attrs.provider_surfaces, & &1.id) == [
             :stocksage_dashboard_panel,
             :stocksage_recent_analyses_panel,
             :stocksage_queue_panel,
             :stocksage_trends_panel
           ]

    assert Enum.map(attrs.provider_surfaces, & &1.path) == [
             "/workspace",
             "/workspace",
             "/workspace",
             "/workspace"
           ]

    assert Enum.all?(attrs.provider_surfaces, &match?(%Surface{kind: :panel}, &1))
    assert Enum.all?(attrs.provider_surfaces, &(&1.metadata.visible_when == :selected_app))

    assert Enum.all?(attrs.provider_surfaces, &match?(%Surface{app_id: :stocksage}, &1))

    assert Enum.map(attrs.surface_catalog, & &1.component) == [
             :analysis_card,
             :agent_report_card,
             :parity_card,
             :debate_round_card
           ]
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    error ->
      if attempts == 1 do
        reraise error, __STACKTRACE__
      else
        Process.sleep(10)
        assert_eventually(fun, attempts - 1)
      end
  end

  defp repo_root, do: Path.expand("../../../../", __DIR__)
end
