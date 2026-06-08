defmodule AllbertArtifacts.PluginTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.App.Bootstrap, as: AppBootstrap
  alias AllbertAssist.Plugin.Bootstrap, as: PluginBootstrap
  alias AllbertAssist.Plugin.ChildSupervisor
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  setup do
    plugin_registry = :"artifacts_plugin_registry_#{System.unique_integer([:positive])}"
    plugin_table = :"artifacts_plugin_table_#{System.unique_integer([:positive])}"
    child_supervisor = :"artifacts_child_supervisor_#{System.unique_integer([:positive])}"

    app_registry = :"artifacts_app_registry_#{System.unique_integer([:positive])}"
    app_table = :"artifacts_app_table_#{System.unique_integer([:positive])}"
    app_supervisor = :"artifacts_app_supervisor_#{System.unique_integer([:positive])}"

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

  test "plugin contract contributes the Artifacts app and no authority" do
    assert AllbertArtifacts.Plugin.plugin_id() == "allbert.artifacts"
    assert AllbertArtifacts.Plugin.apps() == [AllbertArtifacts.App]
    assert AllbertArtifacts.Plugin.actions() == []
    assert AllbertArtifacts.Plugin.channels() == []
    assert AllbertArtifacts.Plugin.skill_paths() == []
    assert AllbertArtifacts.Plugin.settings_schema() == []
    assert AllbertArtifacts.Plugin.child_spec([]) == :ignore

    assert AllbertArtifacts.App.app_id() == :allbert_artifacts
    assert AllbertArtifacts.App.actions() == []
    assert AllbertArtifacts.App.memory_namespace() == nil
  end

  test "discovery finds Artifacts Browser as a shipped source-tree plugin" do
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

    assert {:module, AllbertArtifacts.Plugin, _opts} =
             Enum.find(discoveries, &match?({:module, AllbertArtifacts.Plugin, _}, &1))
  end

  test "bootstrap registers the plugin and app", %{
    plugin_registry: plugin_registry,
    child_supervisor: child_supervisor,
    app_registry: app_registry
  } do
    start_supervised!(
      {PluginBootstrap,
       name: :"artifacts_plugin_bootstrap_#{System.unique_integer([:positive])}",
       registry: plugin_registry,
       child_supervisor: child_supervisor,
       discoveries: [{:module, AllbertArtifacts.Plugin, [source: :shipped]}]}
    )

    assert_eventually(fn ->
      assert [%{plugin_id: "allbert.artifacts"}] =
               PluginRegistry.registered_plugins(server: plugin_registry)
    end)

    start_supervised!(
      {AppBootstrap,
       name: :"artifacts_app_bootstrap_#{System.unique_integer([:positive])}",
       registry: app_registry,
       plugin_registry: plugin_registry}
    )

    assert_eventually(fn ->
      assert {:ok, entry} = AppRegistry.lookup(:allbert_artifacts, server: app_registry)
      assert entry.module == AllbertArtifacts.App
    end)
  end

  defp repo_root do
    __DIR__
    |> Path.expand()
    |> Path.join("../../../..")
    |> Path.expand()
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    exception in [ExUnit.AssertionError] ->
      if attempts == 1 do
        reraise exception, __STACKTRACE__
      else
        Process.sleep(25)
        assert_eventually(fun, attempts - 1)
      end
  end
end
