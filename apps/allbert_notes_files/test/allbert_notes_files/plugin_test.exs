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
  alias AllbertAssist.Skills.Registry, as: SkillsRegistry
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node

  setup do
    ensure_plugin!("allbert.notes_files", AllbertNotesFiles.Plugin)
    app_registered? = AppRegistry.known_app_id?(:notes_files)

    unless app_registered? do
      assert {:ok, :notes_files} = AppRegistry.register(AllbertNotesFiles.App)
    end

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
      unless app_registered?, do: AppRegistry.unregister(:notes_files)
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
    # v1.4 M9: an extracted pack ships its skills in its own application's priv,
    # not under plugins/. The pack addresses them through Application.app_dir/2,
    # so this is the build tree in test and the release tree when packaged.
    assert String.ends_with?(skill_root, "allbert_notes_files/priv/skills")
    assert AllbertNotesFiles.Plugin.child_spec([]) == :ignore
  end

  test "reference skills use canonical Allbert capability metadata" do
    assert {:ok, skills} = SkillsRegistry.list(%{})
    assert {:ok, diagnostics} = SkillsRegistry.diagnostics(%{})

    search = Enum.find(skills, &(&1.name == "search-notes"))
    write = Enum.find(skills, &(&1.name == "write-note"))

    assert search.plugin_id == "allbert.notes_files"
    assert search.kind == :capability_candidate
    assert search.capability_contract.actions == ["search_notes"]
    assert search.capability_contract.permissions == ["read_only"]
    assert search.capability_contract.confirmation == "not_required"
    assert search.contract_validation.status == :valid

    assert write.plugin_id == "allbert.notes_files"
    assert write.kind == :capability_candidate
    assert write.capability_contract.actions == ["write_note"]
    assert write.capability_contract.permissions == ["notes_file_write"]
    assert write.capability_contract.confirmation == "required"
    assert write.contract_validation.status == :valid

    notes_skill_paths =
      AllbertNotesFiles.Plugin.skill_paths()
      |> Enum.map(&Path.expand/1)

    refute Enum.any?(diagnostics, fn diagnostic ->
             notes_skill_diagnostic?(diagnostic, notes_skill_paths) and
               diagnostic.code in [:unknown_frontmatter_field, :unknown_allbert_metadata]
           end)
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

    # v1.4 M9 moved settings OWNERSHIP from the App path to the pack, and this is
    # the identity-preservation proof the milestone exists for: the App now
    # contributes nothing, the pack contributes the fragment, and the id, keys,
    # and defaults are byte-identical to what the App path produced. Asserting
    # both halves is the point -- one alone would let the fragment disappear or
    # be contributed twice without failing.
    assert Fragments.app_fragments(app: [server: app_registry]) == []

    fragment = AllbertNotesFiles.SettingsFragment.fragment()
    assert fragment.id == "app:notes_files"
    assert fragment.owner == :notes_files
    assert fragment.source == :app
    assert fragment.schema["apps.notes_files.notes_root"].default == "<ALLBERT_HOME>/notes"
    assert fragment.schema["apps.notes_files.max_results"].default == 25

    assert AllbertNotesFiles.Pack.settings_fragments() == [AllbertNotesFiles.SettingsFragment]

    assert Enum.sort(Enum.map(AllbertNotesFiles.SettingsFragment.safe_write_rows(), &elem(&1, 1))) ==
             Enum.sort(fragment.safe_write_keys)

    descriptors = ExtensionsRegistry.registered_intent_descriptors(app: [server: app_registry])

    assert Enum.any?(
             descriptors,
             &(&1.app_id == :notes_files and &1.action_name == "search_notes")
           )

    assert %{
             required_slots: [:title, :body],
             optional_slots: [:path],
             slot_extractors: %{title: :title_phrase, body: :body_phrase}
           } =
             Enum.find(
               descriptors,
               &(&1.app_id == :notes_files and &1.action_name == "write_note")
             )

    assert %{
             required_slots: [:path],
             slot_extractors: %{path: :note_path_phrase}
           } =
             Enum.find(
               descriptors,
               &(&1.app_id == :notes_files and &1.action_name == "read_note")
             )
  end

  test "workspace panel declares the action-backed notes component" do
    surfaces = AllbertNotesFiles.App.workspace_panel_surfaces(%{})

    assert [%Surface{id: :notes_files_panel}] = surfaces

    assert %Node{component: :panel, children: [%Node{component: :notes_files_panel}]} =
             hd(hd(surfaces).nodes)

    assert Enum.all?(
             surfaces,
             &(Surface.validate_surface_catalog(&1, AllbertNotesFiles.App.surface_catalog()) ==
                 :ok)
           )
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

  defp notes_skill_diagnostic?(diagnostic, notes_skill_paths) do
    source_path = diagnostic |> Map.get(:source_path, "") |> to_string() |> Path.expand()
    Enum.any?(notes_skill_paths, &String.starts_with?(source_path, &1))
  end

  # Registering only when absent, rather than clearing first. A setup-time
  # `PluginRegistry.clear/0` wipes the whole shipped catalog and revokes the
  # request's readiness epoch while the catalog recomposes; registration is
  # itself effect-gated, so a subsequent register/composition can then fail
  # with :metadata_generation_moved or :product_not_ready. Register only when
  # the plugin isn't already present, and never clear it back out in on_exit.
  defp ensure_plugin!(plugin_id, module) do
    unless match?({:ok, _entry}, PluginRegistry.lookup(plugin_id)) do
      {:ok, ^plugin_id} = PluginRegistry.register_module(module)
    end

    :ok
  end
end
