defmodule StockSage.PluginTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.App.Validator, as: AppValidator
  alias AllbertAssist.Plugin.Bootstrap, as: PluginBootstrap
  alias AllbertAssist.Plugin.ChildSupervisor
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

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
             StockSage.Actions.QueueAnalysis
           ]

    assert StockSage.Plugin.child_spec([]) == :ignore
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

  test "bootstrap registers plugin and app without StockSageStub", %{
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

      assert %{active: 0} = DynamicSupervisor.count_children(child_supervisor)
    end)

    assert {:ok, :stocksage} = AppRegistry.register(StockSage.App, server: app_registry)
    assert {:ok, entry} = AppRegistry.lookup(:stocksage, server: app_registry)
    assert entry.module == StockSage.App
    refute entry.module == AllbertAssist.App.StockSageStub
    assert {:ok, :stocksage} = AppRegistry.normalize_app_id("stocksage", server: app_registry)
    assert {:ok, :stocksage} = AppRegistry.normalize_app_id(:stocksage, server: app_registry)
  end

  test "StockSage app validates against the v0.18 surface provider contract" do
    assert :ok = StockSage.App.validate([])
    assert {:ok, %{app_id: :stocksage}} = AppValidator.validate(StockSage.App)
    assert StockSage.App.surfaces() == []
    assert StockSage.App.surface_catalog() == []
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
