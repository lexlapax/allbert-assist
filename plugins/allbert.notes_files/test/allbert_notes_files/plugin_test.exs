defmodule AllbertNotesFiles.PluginTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.App.Bootstrap, as: AppBootstrap
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.App.Validator, as: AppValidator
  alias AllbertAssist.Extensions.Registry, as: ExtensionsRegistry
  alias AllbertAssist.Plugin.Bootstrap, as: PluginBootstrap
  alias AllbertAssist.Plugin.ChildSupervisor
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  setup do
    original_plugins = PluginRegistry.registered_plugins()
    PluginRegistry.clear()
    assert {:ok, "allbert.notes_files"} = PluginRegistry.register_module(AllbertNotesFiles.Plugin)

    plugin_registry = :"notes_files_plugin_registry_#{System.unique_integer([:positive])}"
    plugin_table = :"notes_files_plugin_table_#{System.unique_integer([:positive])}"
    child_supervisor = :"notes_files_child_supervisor_#{System.unique_integer([:positive])}"

    app_registry = :"notes_files_app_registry_#{System.unique_integer([:positive])}"
    app_table = :"notes_files_app_table_#{System.unique_integer([:positive])}"
    app_supervisor = :"notes_files_app_supervisor_#{System.unique_integer([:positive])}"

    start_supervised!({PluginRegistry, name: plugin_registry, table_name: plugin_table})
    start_supervised!({ChildSupervisor, name: child_supervisor})
    start_supervised!({DynamicSupervisor, name: app_supervisor, strategy: :one_for_one})

    start_supervised!(
      {AppRegistry, name: app_registry, table_name: app_table, dynamic_supervisor: app_supervisor}
    )

    on_exit(fn ->
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
    end)

    %{
      plugin_registry: plugin_registry,
      child_supervisor: child_supervisor,
      app_registry: app_registry
    }
  end

  test "plugin contract contributes the notes/files reference app, actions, and skills" do
    assert AllbertNotesFiles.Plugin.plugin_id() == "allbert.notes_files"
    assert AllbertNotesFiles.Plugin.apps() == [AllbertNotesFiles.App]

    assert AllbertNotesFiles.Plugin.actions() == [
             AllbertNotesFiles.Actions.SearchNotes,
             AllbertNotesFiles.Actions.ReadNote,
             AllbertNotesFiles.Actions.WriteNote
           ]

    assert [skill_root] = AllbertNotesFiles.Plugin.skill_paths()
    assert String.ends_with?(skill_root, "plugins/allbert.notes_files/skills")
    assert AllbertNotesFiles.Plugin.child_spec([]) == :ignore
  end

  test "discovery finds notes/files as a shipped source-tree plugin" do
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

    assert {:module, AllbertNotesFiles.Plugin, _opts} =
             Enum.find(discoveries, &match?({:module, AllbertNotesFiles.Plugin, _opts}, &1))
  end

  test "bootstrap registers the plugin and app without granting authority", %{
    plugin_registry: plugin_registry,
    child_supervisor: child_supervisor,
    app_registry: app_registry
  } do
    start_supervised!(
      {PluginBootstrap,
       name: :"notes_files_plugin_bootstrap_#{System.unique_integer([:positive])}",
       registry: plugin_registry,
       child_supervisor: child_supervisor,
       discoveries: [{:module, AllbertNotesFiles.Plugin, [source: :shipped]}]}
    )

    start_supervised!(
      {AppBootstrap,
       name: :"notes_files_app_bootstrap_#{System.unique_integer([:positive])}",
       registry: app_registry,
       plugin_registry: plugin_registry}
    )

    assert_eventually(fn ->
      assert [%{plugin_id: "allbert.notes_files", trust_status: :trusted}] =
               PluginRegistry.registered_plugins(server: plugin_registry)

      assert {:ok, entry} = AppRegistry.lookup(:notes_files, server: app_registry)
      assert entry.module == AllbertNotesFiles.App
    end)

    assert [%{namespace: :notes_files, writable: false}] =
             AppRegistry.registered_memory_namespaces(server: app_registry)
  end

  test "app validates surfaces, settings fragment, namespace, and descriptors", %{
    app_registry: app_registry
  } do
    assert {:ok, attrs} = AppValidator.validate(AllbertNotesFiles.App)
    assert attrs.app_id == :notes_files

    assert attrs.memory_namespace == %{
             app_id: :notes_files,
             namespace: :notes_files,
             writable: false,
             description:
               "Read-only declaration for notes/files references; note files never auto-promote into memory."
           }

    assert Enum.map(attrs.provider_surfaces, & &1.id) == [
             :notes_files_list_panel,
             :notes_files_detail_panel
           ]

    assert Enum.all?(attrs.provider_surfaces, &match?(%Surface{kind: :panel}, &1))
    assert Enum.all?(attrs.provider_surfaces, &(&1.metadata.visible_when == :selected_app))
    assert Enum.all?(attrs.provider_surfaces, &(&1.app_id == :notes_files))

    assert %AllbertAssist.Settings.Fragment{} = AllbertNotesFiles.SettingsFragment.fragment()

    assert {:ok, :notes_files} = AppRegistry.register(AllbertNotesFiles.App, server: app_registry)

    assert [fragment] = Fragments.app_fragments(app: [server: app_registry])
    assert fragment.id == "app:notes_files"
    assert fragment.schema["apps.notes_files.notes_root"].default == "<ALLBERT_HOME>/notes"

    assert Enum.any?(
             ExtensionsRegistry.registered_intent_descriptors(app: [server: app_registry]),
             &(&1.app_id == :notes_files and &1.action_name == "search_notes")
           )
  end

  test "workspace panels hydrate note rows from read-only file context" do
    surfaces = AllbertNotesFiles.App.workspace_panel_surfaces(%{})

    assert [%Surface{id: :notes_files_list_panel}, %Surface{id: :notes_files_detail_panel}] =
             surfaces

    assert %Node{component: :panel} = hd(hd(surfaces).nodes)
    assert Enum.all?(surfaces, &(Surface.validate_surface_catalog(&1, []) == :ok))
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
