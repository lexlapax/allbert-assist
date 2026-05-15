defmodule AllbertAssist.Skills.RegistryTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Discovery
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Skills

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR"]

  defmodule AppSkillApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :skill_registry_app

    @impl true
    def display_name, do: "Skill Registry App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def skill_paths do
      Application.get_env(:allbert_assist, __MODULE__, [])
    end
  end

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_app_config = Application.get_env(:allbert_assist, AppSkillApp)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    PluginRegistry.clear()

    root = temp_path("root")
    home = Path.join(root, "home")
    project_root = Path.join(root, "project")
    built_in_root = Path.join(root, "built-in-skills")
    user_interoperable_root = Path.join(root, "agent-skills")

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(root)
      AppRegistry.unregister(:skill_registry_app)
      PluginRegistry.clear()
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(AppSkillApp, original_app_config)
    end)

    {:ok,
     root: root,
     home: home,
     project_root: project_root,
     built_in_root: built_in_root,
     user_interoperable_root: user_interoperable_root}
  end

  test "lists trusted built-in and user skill roots", context do
    write_skill(context.built_in_root, "direct-answer", "direct-answer")
    write_skill(Path.join(context.home, "skills"), "user-note", "user-note")

    assert {:ok, skills} = Skills.list(registry_context(context))

    assert Enum.map(skills, & &1.name) == ["direct-answer", "user-note"]
    assert Enum.find(skills, &(&1.name == "direct-answer")).source_scope == :built_in
    assert Enum.find(skills, &(&1.name == "user-note")).source_scope == :user_native
  end

  test "get accepts snake-case aliases", context do
    write_skill(Path.join(context.home, "skills"), "user-note", "user-note")

    assert {:ok, skill} = Skills.get("user_note", registry_context(context))
    assert skill.name == "user-note"
  end

  test "project skills are pending until the project root is trusted", context do
    project_skills_root = Path.join([context.project_root, ".allbert", "skills"])
    write_skill(project_skills_root, "project-skill", "project-skill")

    pending_context = registry_context(context)
    assert {:ok, []} = Skills.list(pending_context)
    assert {:ok, diagnostics} = Skills.diagnostics(pending_context)
    assert Enum.any?(diagnostics, &(&1.code == :project_skill_pending))

    trusted_context =
      registry_context(context,
        settings: settings(%{"trusted_project_roots" => [context.project_root]})
      )

    assert {:ok, [skill]} = Skills.list(trusted_context)
    assert skill.name == "project-skill"
    assert skill.trust_status == :trusted
  end

  test "disabled skills are hidden and reported", context do
    write_skill(Path.join(context.home, "skills"), "user-note", "user-note")

    registry_context =
      registry_context(context, settings: settings(%{"disabled" => ["user-note"]}))

    assert {:ok, []} = Skills.list(registry_context)
    assert {:ok, diagnostics} = Skills.diagnostics(registry_context)
    assert Enum.any?(diagnostics, &(&1.code == :disabled_skill and &1.name == "user-note"))
  end

  test "trusted project skills take duplicate precedence over user skills", context do
    write_skill(
      Path.join([context.project_root, ".allbert", "skills"]),
      "shared-skill",
      "shared-skill"
    )

    write_skill(Path.join(context.home, "skills"), "shared-skill", "shared-skill")

    registry_context =
      registry_context(context,
        settings: settings(%{"trusted_project_roots" => [context.project_root]})
      )

    assert {:ok, [skill]} = Skills.list(registry_context)
    assert skill.name == "shared-skill"
    assert skill.source_scope == :project_native

    assert {:ok, diagnostics} = Skills.diagnostics(registry_context)
    assert Enum.any?(diagnostics, &(&1.code == :duplicate_skill_hidden))
  end

  test "registered app skill paths are trusted between project and user roots", context do
    app_root = Path.join(context.root, "app-skills")
    write_skill(app_root, "shared-skill", "shared-skill")
    write_skill(Path.join(context.home, "skills"), "shared-skill", "shared-skill")

    Application.put_env(:allbert_assist, AppSkillApp, [app_root])
    assert {:ok, :skill_registry_app} = AppRegistry.register(AppSkillApp)

    assert {:ok, [skill]} = Skills.list(registry_context(context))
    assert skill.name == "shared-skill"
    assert skill.source_scope == :app
    assert skill.trust_status == :trusted

    assert {:ok, diagnostics} = Skills.diagnostics(registry_context(context))

    assert Enum.any?(
             diagnostics,
             &(&1.code == :duplicate_skill_hidden and
                 &1.winning_source_scope == :app and
                 &1.source_scope == :user_native)
           )
  end

  test "trusted plugin skill paths are discovered after app roots and before user roots",
       context do
    plugin_root = Path.join(context.root, "plugin-skills")
    write_skill(plugin_root, "shared-skill", "shared-skill")
    write_skill(Path.join(context.home, "skills"), "shared-skill", "shared-skill")

    assert {:ok, "example.skills"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.skills",
               display_name: "Example Skills",
               version: "0.1.0",
               kind: "skills",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               skill_paths: [plugin_root]
             })

    assert {:ok, [skill]} = Skills.list(registry_context(context))
    assert skill.name == "shared-skill"
    assert skill.source_scope == :plugin
    assert skill.trust_status == :trusted

    assert {:ok, diagnostics} = Skills.diagnostics(registry_context(context))

    assert Enum.any?(
             diagnostics,
             &(&1.code == :duplicate_skill_hidden and
                 &1.winning_source_scope == :plugin and
                 &1.source_scope == :user_native)
           )
  end

  test "pending plugin skill paths stay inspectable but hidden", context do
    plugin_root = Path.join(context.root, "pending-plugin-skills")
    write_skill(plugin_root, "pending-plugin-skill", "pending-plugin-skill")

    assert {:ok, "example.pending"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.pending",
               display_name: "Example Pending",
               version: "0.1.0",
               kind: "skills",
               source: :home,
               status: :enabled,
               trust_status: :pending,
               skill_paths: [plugin_root]
             })

    assert {:ok, []} = Skills.list(registry_context(context))
    assert {:ok, diagnostics} = Skills.diagnostics(registry_context(context))

    assert Enum.any?(
             diagnostics,
             &(&1.code == :plugin_skill_pending and
                 &1.plugin_id == "example.pending" and
                 &1.source_scope == :plugin)
           )
  end

  test "enabled trusted folder plugin contributes skill roots", context do
    plugin_root = Path.join([context.project_root, "plugins", "example.skills"])
    skills_root = Path.join(plugin_root, "skills")
    write_skill(skills_root, "folder-plugin-skill", "folder-plugin-skill")

    File.write!(Path.join(plugin_root, "allbert_plugin.json"), """
    {
      "schema_version": 1,
      "plugin_id": "example.skills",
      "name": "Example Skills",
      "version": "0.1.0",
      "kind": "skills",
      "skill_paths": ["skills"]
    }
    """)

    discoveries =
      Discovery.discover(
        project_root: context.project_root,
        settings: %{
          "enabled" => ["example.skills"],
          "disabled" => [],
          "scan_paths" => [Path.join(context.project_root, "plugins")],
          "trusted_project_roots" => [context.project_root],
          "load_policy" => "shipped_and_skill_only"
        }
      )

    assert [{:entry, entry}] = discoveries
    assert entry.trust_status == :trusted
    assert {:ok, "example.skills"} = PluginRegistry.register_entry(entry)

    assert {:ok, [skill]} = Skills.list(registry_context(context))
    assert skill.name == "folder-plugin-skill"
    assert skill.source_scope == :plugin
    assert skill.trust_status == :trusted
  end

  test "built-in skill names are reserved", context do
    write_skill(Path.join(context.home, "skills"), "append-memory", "append-memory")
    registry_context = registry_context(context)

    assert {:ok, []} = Skills.list(registry_context)
    assert {:ok, diagnostics} = Skills.diagnostics(registry_context)
    assert Enum.any?(diagnostics, &(&1.code == :built_in_name_reserved))
  end

  test "imported cache skills require manual trust policy and explicit enablement", context do
    write_skill(Path.join([context.home, "cache", "skills"]), "imported-skill", "imported-skill")

    disabled_context = registry_context(context)
    assert {:ok, []} = Skills.list(disabled_context)
    assert {:ok, diagnostics} = Skills.diagnostics(disabled_context)
    assert Enum.any?(diagnostics, &(&1.code == :imported_skill_disabled))

    enabled_context =
      registry_context(context,
        settings:
          settings(%{
            "imported_cache_policy" => "enabled_manual_trust",
            "enabled" => ["imported-skill"]
          })
      )

    assert {:ok, [skill]} = Skills.list(enabled_context)
    assert skill.name == "imported-skill"
    assert skill.source_scope == :imported_cache
    assert skill.trust_status == :trusted
  end

  test "imported cache discovery supports source-scoped nested imports", context do
    write_skill(
      Path.join([context.home, "cache", "skills", "skills_sh", "vercel-labs-skills"]),
      "find-skills",
      "find-skills"
    )

    registry_context = registry_context(context)

    assert {:ok, []} = Skills.list(registry_context)
    assert {:ok, diagnostics} = Skills.diagnostics(registry_context)
    assert Enum.any?(diagnostics, &(&1.code == :imported_skill_disabled))
  end

  test "malformed declarations appear in diagnostics", context do
    scan_root = Path.join(context.root, "configured")
    invalid_root = Path.join(scan_root, "invalid")

    File.mkdir_p!(invalid_root)
    File.write!(Path.join(invalid_root, "SKILL.md"), "---\nname: invalid\ndescription: [\n---\n")

    registry_context =
      registry_context(context, settings: settings(%{"scan_paths" => [scan_root]}))

    assert {:ok, diagnostics} = Skills.diagnostics(registry_context)

    assert Enum.any?(
             diagnostics,
             &(&1.code == :invalid_yaml and &1.source_scope == :configured_scan_path)
           )
  end

  test "invalid capability contracts stay inspectable but non-executable", context do
    write_skill(
      Path.join(context.home, "skills"),
      "bad-capability",
      "bad-capability",
      """
      metadata:
        allbert.kind: capability
        allbert.actions: missing_action
        allbert.permissions: root_access
        allbert.confirmation: auto_approve_everything
      """
    )

    assert {:ok, [skill]} = Skills.list(registry_context(context))

    assert skill.name == "bad-capability"
    assert skill.kind == :capability_candidate
    assert skill.contract_validation.status == :invalid
    refute skill.contract_validation.execution_eligible?

    diagnostic_codes = Enum.map(skill.contract_validation.diagnostics, & &1.code)

    assert :unknown_action in diagnostic_codes
    assert :unknown_permission in diagnostic_codes
    assert :unknown_confirmation in diagnostic_codes

    assert {:ok, activation} = Skills.activate("bad-capability", registry_context(context))
    assert activation.capability_contract.validation_status == :invalid
    refute activation.capability_contract.execution_eligible?
  end

  test "legacy built-ins preserve operator skill discovery until the M4 skill pack", context do
    registry_context = registry_context(context, disable_legacy_built_ins: false)

    assert {:ok, skills} = Skills.list(registry_context)

    assert Enum.any?(
             skills,
             &(&1.name == "append-memory" and &1.source_scope == :built_in_legacy)
           )
  end

  defp registry_context(context, overrides \\ []) do
    %{
      built_in_root: context.built_in_root,
      project_root: context.project_root,
      user_interoperable_root: context.user_interoperable_root,
      disable_legacy_built_ins: true
    }
    |> Map.merge(Map.new(overrides))
  end

  defp settings(overrides) do
    Map.merge(
      %{
        "scan_paths" => [],
        "trusted_project_roots" => [],
        "enabled" => [],
        "disabled" => [],
        "imported_cache_policy" => "disabled"
      },
      Map.new(overrides)
    )
  end

  defp write_skill(root, directory, name, extra_frontmatter \\ "") do
    skill_root = Path.join(root, directory)
    File.mkdir_p!(skill_root)

    File.write!(Path.join(skill_root, "SKILL.md"), """
    ---
    name: #{name}
    description: #{name} test skill.
    #{extra_frontmatter}
    ---

    ## Workflow

    Inspect only.
    """)
  end

  defp temp_path(name) do
    Path.join(System.tmp_dir!(), "allbert-registry-#{name}-#{System.unique_integer([:positive])}")
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
