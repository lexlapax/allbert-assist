defmodule AllbertAssist.Actions.RegistryTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Action
  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  defmodule PluginEcho do
    use Jido.Action,
      name: "plugin_echo",
      description: "Echo from a plugin fixture.",
      schema: [text: [type: :string, required: true]]

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(%{text: text}, _context), do: {:ok, %{message: "plugin: #{text}", status: :completed}}
  end

  defmodule DuplicateDirectAnswer do
    use Jido.Action,
      name: "direct_answer",
      description: "Duplicate direct answer from a plugin fixture.",
      schema: []

    def capability do
      %{
        permission: :read_only,
        exposure: :agent,
        execution_mode: :read_only,
        skill_backed?: false,
        confirmation: :not_required
      }
    end

    @impl true
    def run(_params, _context), do: {:ok, %{message: "duplicate", status: :completed}}
  end

  defmodule ActionTaggingApp do
    use AllbertAssist.App

    @impl true
    def app_id, do: :action_tagging_app

    @impl true
    def display_name, do: "Action Tagging App"

    @impl true
    def version, do: "0.15.0"

    @impl true
    def validate(_opts), do: :ok

    @impl true
    def actions, do: [DirectAnswer]
  end

  setup do
    PluginRegistry.clear()

    on_exit(fn ->
      PluginRegistry.clear()
      PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
      PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    end)

    :ok
  end

  test "returns the canonical runtime action names in stable order" do
    assert Registry.names() == [
             "direct_answer",
             "append_memory",
             "read_recent_memory",
             "list_skills",
             "read_skill",
             "activate_skill",
             "plan_shell_command",
             "run_shell_command",
             "unsupported_resource_workflow",
             "external_network_request",
             "plan_package_install",
             "search_online_skills",
             "show_online_skill",
             "list_settings",
             "read_setting",
             "update_setting",
             "explain_setting",
             "list_provider_profiles",
             "list_model_profiles",
             "set_provider_credential",
             "list_channels",
             "show_channel",
             "list_apps",
             "show_app",
             "list_plugins",
             "show_plugin",
             "validate_skill",
             "create_skill",
             "run_skill_script",
             "run_package_install",
             "audit_online_skill",
             "import_online_skill",
             "import_remote_skill",
             "import_local_skill",
             "security_status",
             "security_review",
             "sandbox_doctor",
             "build_sandbox_bundle",
             "run_sandbox_command",
             "run_sandbox_gate",
             "discard_sandbox_bundle",
             "list_confirmations",
             "show_confirmation",
             "approve_confirmation",
             "deny_confirmation",
             "expire_confirmations",
             "list_resource_grants",
             "show_resource_grant",
             "revoke_resource_grant",
             "remember_resource_grant",
             "set_active_app",
             "clear_active_app",
             "show_session_scratchpad",
             "record_trace",
             "explain_intent",
             "list_intent_candidates",
             "list_memory_entries",
             "read_memory_entry",
             "review_memory_entry",
             "update_memory_entry",
             "delete_memory_entry",
             "prune_memory_entries",
             "search_memory",
             "compile_memory_index",
             "summarize_memory_category",
             "list_memory_category_summary",
             "promote_conversation_turn",
             "sync_app_lesson",
             "list_objectives",
             "show_objective",
             "cancel_objective",
             "continue_objective",
             "delegate_agent",
             "registry_health",
             "trace_summary",
             "manage_workspace_tile",
             "revert_tile_revision",
             "record_workspace_offline_update",
             "dismiss_workspace_ephemeral",
             "set_workspace_theme"
           ]

    assert Registry.duplicate_names() == []
  end

  test "returns the intent-agent action surface without internal actions" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    assert "direct_answer" in agent_action_names
    assert "set_provider_credential" in agent_action_names
    assert "list_channels" in agent_action_names
    assert "show_channel" in agent_action_names
    assert "list_apps" in agent_action_names
    assert "show_app" in agent_action_names
    assert "list_plugins" in agent_action_names
    assert "show_plugin" in agent_action_names
    refute "security_status" in agent_action_names
    refute "security_review" in agent_action_names
    refute "record_trace" in agent_action_names
  end

  test "returns canonical capability metadata for every registered action" do
    capabilities = Registry.capabilities()

    assert Enum.map(capabilities, & &1.name) == Registry.names()
    assert Enum.all?(capabilities, &(&1.module in Registry.modules()))
    assert Enum.all?(capabilities, &is_atom(&1.permission))
    assert Enum.all?(capabilities, &(&1.exposure in [:agent, :internal]))

    assert Enum.map(Registry.agent_capabilities(), & &1.name) ==
             Enum.map(Registry.agent_modules(), & &1.name())

    assert Enum.map(Registry.internal_capabilities(), & &1.name) == [
             "validate_skill",
             "create_skill",
             "run_skill_script",
             "run_package_install",
             "audit_online_skill",
             "import_online_skill",
             "import_remote_skill",
             "import_local_skill",
             "security_status",
             "security_review",
             "sandbox_doctor",
             "build_sandbox_bundle",
             "run_sandbox_command",
             "run_sandbox_gate",
             "discard_sandbox_bundle",
             "list_confirmations",
             "show_confirmation",
             "approve_confirmation",
             "deny_confirmation",
             "expire_confirmations",
             "list_resource_grants",
             "show_resource_grant",
             "revoke_resource_grant",
             "remember_resource_grant",
             "set_active_app",
             "clear_active_app",
             "show_session_scratchpad",
             "record_trace",
             "explain_intent",
             "list_intent_candidates",
             "list_memory_entries",
             "read_memory_entry",
             "review_memory_entry",
             "update_memory_entry",
             "delete_memory_entry",
             "prune_memory_entries",
             "search_memory",
             "compile_memory_index",
             "summarize_memory_category",
             "list_memory_category_summary",
             "promote_conversation_turn",
             "sync_app_lesson",
             "list_objectives",
             "show_objective",
             "cancel_objective",
             "continue_objective",
             "delegate_agent",
             "registry_health",
             "trace_summary",
             "manage_workspace_tile",
             "revert_tile_revision",
             "record_workspace_offline_update",
             "dismiss_workspace_ephemeral",
             "set_workspace_theme"
           ]

    assert {:ok, append_memory} = Registry.capability("append_memory")
    assert append_memory.permission == :memory_write
    assert append_memory.skill_backed?

    assert {:ok, activate_skill} = Registry.capability("activate_skill")
    refute activate_skill.skill_backed?
    assert activate_skill.exposure == :agent

    assert {:ok, create_skill} = Registry.capability("create_skill")
    assert create_skill.permission == :skill_write
    assert create_skill.exposure == :internal
    refute create_skill.skill_backed?

    assert {:ok, list_objectives} = Registry.capability("list_objectives")
    assert list_objectives.permission == :read_only
    assert list_objectives.exposure == :internal
    assert list_objectives.execution_mode == :objectives_read

    assert {:ok, cancel_objective} = Registry.capability("cancel_objective")
    assert cancel_objective.permission == :objective_write
    assert cancel_objective.exposure == :internal
    assert cancel_objective.execution_mode == :objective_engine

    assert {:ok, delegate_agent} = Registry.capability("delegate_agent")
    assert delegate_agent.permission == :objective_write
    assert delegate_agent.execution_mode == :objective_delegate

    assert {:ok, run_skill_script} = Registry.capability("run_skill_script")
    assert run_skill_script.permission == :skill_script_execute
    assert run_skill_script.exposure == :internal
    assert run_skill_script.execution_mode == :skill_script_process
    assert run_skill_script.skill_backed?
    assert run_skill_script.confirmation == :required

    assert {:ok, run_shell_command} = Registry.capability("run_shell_command")
    assert run_shell_command.permission == :command_execute
    assert run_shell_command.exposure == :agent
    assert run_shell_command.execution_mode == :local_process
    assert run_shell_command.confirmation == :required
    assert run_shell_command.resumable?

    assert {:ok, external_network_request} = Registry.capability("external_network_request")
    assert external_network_request.permission == :external_network
    assert external_network_request.execution_mode == :req_http
    assert external_network_request.confirmation == :required
    assert external_network_request.resumable?

    assert {:ok, unsupported_resource_workflow} =
             Registry.capability("unsupported_resource_workflow")

    assert unsupported_resource_workflow.permission == :read_only
    assert unsupported_resource_workflow.execution_mode == :unsupported_resource_workflow
    assert unsupported_resource_workflow.confirmation == :not_required
    assert unsupported_resource_workflow.skill_backed?

    assert {:ok, plan_package_install} = Registry.capability("plan_package_install")
    assert plan_package_install.permission == :read_only
    assert plan_package_install.execution_mode == :package_install_plan
    assert plan_package_install.exposure == :agent
    refute plan_package_install.resumable?

    assert {:ok, run_package_install} = Registry.capability("run_package_install")
    assert run_package_install.permission == :package_install
    assert run_package_install.execution_mode == :package_manager_process
    assert run_package_install.exposure == :internal
    assert run_package_install.confirmation == :required
    assert run_package_install.resumable?

    assert {:ok, delete_memory_entry} = Registry.capability("delete_memory_entry")
    assert delete_memory_entry.permission == :memory_write
    assert delete_memory_entry.execution_mode == :memory_archive
    assert delete_memory_entry.confirmation == :required
    assert delete_memory_entry.resumable?

    assert {:ok, sync_app_lesson} = Registry.capability("sync_app_lesson")
    assert sync_app_lesson.permission == :memory_write
    assert sync_app_lesson.execution_mode == :app_memory_sync
    assert sync_app_lesson.exposure == :internal
    assert sync_app_lesson.confirmation == :required
    assert sync_app_lesson.resumable?

    assert {:ok, search_online_skills} = Registry.capability("search_online_skills")
    assert search_online_skills.permission == :external_network
    assert search_online_skills.execution_mode == :online_skill_search
    assert search_online_skills.resumable?

    assert {:ok, import_online_skill} = Registry.capability("import_online_skill")
    assert import_online_skill.permission == :online_skill_import
    assert import_online_skill.confirmation == :required
    assert import_online_skill.resumable?

    assert {:ok, import_remote_skill} = Registry.capability("import_remote_skill")
    assert import_remote_skill.permission == :online_skill_import
    assert import_remote_skill.execution_mode == :direct_skill_import
    assert import_remote_skill.confirmation == :required
    assert import_remote_skill.resumable?

    assert {:ok, import_local_skill} = Registry.capability("import_local_skill")
    assert import_local_skill.permission == :skill_write
    assert import_local_skill.execution_mode == :local_skill_import
    assert import_local_skill.confirmation == :required
    assert import_local_skill.resumable?

    assert {:ok, registry_health} = Registry.capability("registry_health")
    assert registry_health.permission == :read_only
    assert registry_health.execution_mode == :read_only
    assert registry_health.exposure == :internal
    assert registry_health.confirmation == :not_required

    assert {:ok, trace_summary} = Registry.capability("trace_summary")
    assert trace_summary.permission == :read_only
    assert trace_summary.execution_mode == :read_only
    assert trace_summary.exposure == :internal
    assert trace_summary.confirmation == :not_required

    assert {:ok, manage_workspace_tile} = Registry.capability("manage_workspace_tile")
    assert manage_workspace_tile.permission == :workspace_canvas_write
    assert manage_workspace_tile.execution_mode == :workspace_canvas_write
    assert manage_workspace_tile.exposure == :internal
    assert manage_workspace_tile.confirmation == :not_required

    assert {:ok, revert_tile_revision} = Registry.capability("revert_tile_revision")
    assert revert_tile_revision.permission == :workspace_canvas_write
    assert revert_tile_revision.execution_mode == :workspace_canvas_write
    assert revert_tile_revision.exposure == :internal
    assert revert_tile_revision.confirmation == :not_required

    assert {:ok, record_workspace_offline_update} =
             Registry.capability("record_workspace_offline_update")

    assert record_workspace_offline_update.permission == :workspace_canvas_write
    assert record_workspace_offline_update.execution_mode == :workspace_canvas_write
    assert record_workspace_offline_update.exposure == :internal
    assert record_workspace_offline_update.confirmation == :not_required

    assert {:ok, dismiss_workspace_ephemeral} =
             Registry.capability("dismiss_workspace_ephemeral")

    assert dismiss_workspace_ephemeral.permission == :workspace_canvas_write
    assert dismiss_workspace_ephemeral.execution_mode == :workspace_canvas_write
    assert dismiss_workspace_ephemeral.exposure == :internal
    assert dismiss_workspace_ephemeral.confirmation == :not_required

    assert {:ok, set_workspace_theme} = Registry.capability("set_workspace_theme")
    assert set_workspace_theme.permission == :settings_write
    assert set_workspace_theme.execution_mode == :settings_write
    assert set_workspace_theme.exposure == :internal
    assert set_workspace_theme.confirmation == :not_required

    assert {:ok, explain_intent} = Registry.capability("explain_intent")
    assert explain_intent.permission == :read_only
    assert explain_intent.execution_mode == :read_only
    assert explain_intent.exposure == :internal
    assert explain_intent.confirmation == :not_required

    assert {:ok, list_apps} = Registry.capability("list_apps")
    assert list_apps.permission == :read_only
    assert list_apps.execution_mode == :settings_read
    assert list_apps.exposure == :agent
    refute list_apps.skill_backed?

    assert {:ok, show_app} = Registry.capability("show_app")
    assert show_app.permission == :read_only
    assert show_app.execution_mode == :settings_read
    assert show_app.exposure == :agent

    assert {:ok, list_plugins} = Registry.capability("list_plugins")
    assert list_plugins.permission == :read_only
    assert list_plugins.execution_mode == :settings_read
    assert list_plugins.exposure == :agent
    refute list_plugins.skill_backed?

    assert {:ok, show_plugin} = Registry.capability("show_plugin")
    assert show_plugin.permission == :read_only
    assert show_plugin.execution_mode == :settings_read
    assert show_plugin.exposure == :agent

    assert {:ok, approve_confirmation} = Registry.capability("approve_confirmation")
    assert approve_confirmation.permission == :confirmation_decide
    assert approve_confirmation.exposure == :internal
    refute approve_confirmation.resumable?

    assert {:ok, list_resource_grants} = Registry.capability("list_resource_grants")
    assert list_resource_grants.permission == :read_only
    assert list_resource_grants.execution_mode == :resource_grant_read
    refute list_resource_grants.resumable?

    assert {:ok, revoke_resource_grant} = Registry.capability("revoke_resource_grant")
    assert revoke_resource_grant.permission == :confirmation_decide
    assert revoke_resource_grant.execution_mode == :resource_grant_revoke

    assert {:ok, set_active_app} = Registry.capability("set_active_app")
    assert set_active_app.permission == :settings_write
    assert set_active_app.execution_mode == :settings_write
    assert set_active_app.exposure == :internal
    assert set_active_app.confirmation == :not_required

    assert {:ok, clear_active_app} = Registry.capability("clear_active_app")
    assert clear_active_app.permission == :settings_write
    assert clear_active_app.execution_mode == :settings_write

    assert {:ok, show_session_scratchpad} = Registry.capability("show_session_scratchpad")
    assert show_session_scratchpad.permission == :read_only
    assert show_session_scratchpad.execution_mode == :settings_read

    assert {:error, {:unknown_action, "missing_action"}} = Registry.capability("missing_action")
  end

  test "reports resumable targets from capability metadata" do
    assert Registry.resumable?("external_network_request")
    assert Registry.resumable?(:run_shell_command)
    assert Registry.resumable?("run_package_install")
    assert Registry.resumable?("search_online_skills")
    assert Registry.resumable?("import_online_skill")
    assert Registry.resumable?("import_remote_skill")
    assert Registry.resumable?("import_local_skill")
    assert Registry.resumable?("run_skill_script")
    assert Registry.resumable?("delete_memory_entry")
    assert Registry.resumable?("prune_memory_entries")
    assert Registry.resumable?("promote_conversation_turn")

    refute Registry.resumable?("direct_answer")
    refute Registry.resumable?("plan_package_install")
    refute Registry.resumable?("missing_action")
  end

  test "built-in registered actions declare capability metadata on their modules" do
    for module <- Registry.modules() do
      assert Action.allbert_action?(module)
      assert {:ok, module_capability} = Action.validate_capability(module.capability())
      assert {:ok, registry_capability} = Registry.capability(module)

      assert registry_capability.permission == module_capability.permission
      assert registry_capability.exposure == module_capability.exposure
      assert registry_capability.execution_mode == module_capability.execution_mode
      assert registry_capability.skill_backed? == module_capability.skill_backed?
      assert registry_capability.confirmation == module_capability.confirmation
    end

    refute Action.allbert_action?(Multiply)
  end

  test "resolves registered actions by name and module only" do
    assert {:ok, DirectAnswer} = Registry.resolve("direct_answer")
    assert {:ok, DirectAnswer} = Registry.resolve(:direct_answer)
    assert {:ok, DirectAnswer} = Registry.resolve(DirectAnswer)

    assert {:error, {:unknown_action, "missing_action"}} = Registry.resolve("missing_action")
    assert {:error, {:unknown_action, Multiply}} = Registry.resolve(Multiply)
    refute Registry.registered_module?(Multiply)
  end

  test "stamps app ids onto capabilities for registered app actions" do
    on_exit(fn -> AllbertAssist.App.Registry.unregister(:action_tagging_app) end)

    assert {:ok, :action_tagging_app} = AllbertAssist.App.Registry.register(ActionTaggingApp)

    assert {:ok, direct_answer} = Registry.capability("direct_answer")
    assert direct_answer.app_id == :action_tagging_app

    assert %{app_id: :action_tagging_app} = Capability.summary(direct_answer)

    assert [%{name: "direct_answer", app_id: :action_tagging_app}] =
             Enum.map(
               Registry.capabilities_for_app(:action_tagging_app),
               &Capability.summary/1
             )

    assert Registry.capabilities_for_app(:missing_app) == []
  end

  test "merges plugin-contributed actions with capability provenance" do
    assert {:ok, "example.actions"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.actions",
               display_name: "Example Actions",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [PluginEcho]
             })

    assert "plugin_echo" in Registry.names()
    assert {:ok, PluginEcho} = Registry.resolve("plugin_echo")
    assert Registry.registered_module?(PluginEcho)
    assert PluginEcho in Registry.agent_modules()

    assert {:ok, capability} = Registry.capability("plugin_echo")
    assert capability.permission == :read_only
    assert capability.exposure == :agent
    assert capability.plugin_id == "example.actions"

    assert %{plugin_id: "example.actions"} = Capability.summary(capability)
  end

  test "rejects duplicate plugin action names with diagnostics" do
    assert {:ok, "example.duplicate_action"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.duplicate_action",
               display_name: "Example Duplicate Action",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [DuplicateDirectAnswer]
             })

    assert {:ok, DirectAnswer} = Registry.resolve("direct_answer")
    refute Registry.registered_module?(DuplicateDirectAnswer)
    assert Registry.duplicate_names() == []

    assert [
             %{
               plugin_id: "example.duplicate_action",
               kind: :duplicate_action_name,
               action_name: "direct_answer",
               action_module: DuplicateDirectAnswer
             }
           ] = Registry.diagnostics()
  end
end
