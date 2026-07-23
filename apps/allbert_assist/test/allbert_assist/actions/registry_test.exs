defmodule AllbertAssist.Actions.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Action
  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Plugin.Entry, as: PluginEntry
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias Jido.Signal.Bus

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
      ShippedRegistries.restore!()
    end)

    :ok
  end

  test "retry safety is safe only for reviewed idempotent modes and unknown otherwise" do
    assert {:ok, safe} = Registry.capability("list_settings")
    assert safe.retry_safety == :safe

    assert {:ok, unknown} = Registry.capability("send_channel_message")
    assert unknown.retry_safety == :unknown
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
             "set_notes_root",
             "explain_setting",
             "list_provider_profiles",
             "list_model_profiles",
             "set_provider_credential",
             "doctor_model_profile",
             "doctor_voice_provider",
             "set_active_model_profile",
             "generate_image",
             "synthesize_voice",
             "list_channels",
             "show_channel",
             "channel_setup_check",
             "resume_thread_on_channel",
             "list_apps",
             "show_app",
             "list_plugins",
             "show_plugin",
             "get_public_call_result",
             "preview_plan",
             "open_calendar_panel",
             "open_mail_panel",
             "open_github_panel",
             "list_marketplace_entries",
             "list_objectives",
             "find_mcp_tools",
             "send_email",
             "send_channel_message",
             "create_calendar_event",
             "install_marketplace_bundle",
             "create_skill",
             "continue_objective",
             "cancel_objective",
             "cancel_objective_run",
             "steer_objective_run",
             "read",
             "grep",
             "glob",
             "write",
             "edit",
             "bash",
             "start_fanout",
             "whatsapp_doctor",
             "signal_doctor",
             "mcp_doctor_server",
             "mcp_list_tools",
             "mcp_list_resources",
             "mcp_read_resource",
             "mcp_call_tool",
             "mcp_fetch_server_manifest",
             "mcp_evaluate_server",
             "mcp_server_connect",
             "mcp_scan_enable",
             "mcp_scan_pause",
             "mcp_scan_resume",
             "mcp_scan_run_once",
             "find_local_tools",
             "find_tools",
             "discover_patterns",
             "create_self_improvement_draft",
             "discard_self_improvement_draft",
             "promote_skill_draft",
             "promote_workflow_draft",
             "promote_memory_draft",
             "promote_template_draft",
             "promote_objective_draft",
             "promote_capability_gap_draft",
             "validate_skill",
             "run_skill_script",
             "run_package_install",
             "audit_online_skill",
             "import_online_skill",
             "import_remote_skill",
             "import_local_skill",
             "marketplace_doctor",
             "inspect_marketplace_entry",
             "rollback_marketplace_install",
             "list_installed_marketplace_bundles",
             "verify_marketplace_bundle_hash",
             "put_artifact",
             "get_artifact",
             "list_artifacts",
             "artifact_threads",
             "delete_artifact",
             "artifact_doctor",
             "security_status",
             "security_review",
             "sandbox_doctor",
             "build_sandbox_bundle",
             "run_sandbox_command",
             "run_sandbox_gate",
             "discard_sandbox_bundle",
             "operator_status",
             "operator_confirmations",
             "operator_events",
             "operator_channels",
             "operator_setting_get",
             "surface_policy_read",
             "surface_policy_update",
             "settings_doctor",
             "model_doctor",
             "resolved_settings_snapshot",
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
             "capture_workspace_voice",
             "transcribe_voice",
             "voice_local_runtime_doctor",
             "voice_local_runtime_start",
             "record_trace",
             "explain_intent",
             "list_intent_candidates",
             "intent_doctor",
             "intent_list_descriptors",
             "intent_show_descriptor",
             "intent_coverage",
             "intent_eval_run",
             "intent_list_review",
             "optimize_intent_descriptors",
             "promote_intent_descriptor",
             "reindex_intent_descriptors",
             "edit_intent_descriptor",
             "disable_intent_descriptor",
             "enable_intent_descriptor",
             "intent_eval_baseline",
             "intent_eval_capture",
             "intent_eval_add",
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
             "retrieve_active_memory",
             "promote_conversation_turn",
             "sync_app_lesson",
             "show_objective",
             "delegate_agent",
             "list_workflows",
             "inspect_workflow",
             "expand_workflow",
             "start_plan_run",
             "plan_step_confirm",
             "cancel_plan_run",
             "list_plan_runs",
             "registry_health",
             "trace_summary",
             "list_jobs",
             "pause_job",
             "resume_job",
             "run_job",
             "create_job",
             "rename_thread",
             "persist_approval_media_response",
             "first_model_detect",
             "install_ollama",
             "pull_model",
             "serve_health",
             "service_control",
             "restore_database_backup",
             "vault_status",
             "migrate_secrets",
             "apply_persona_profile",
             "manage_workspace_tile",
             "revert_tile_revision",
             "record_workspace_offline_update",
             "dismiss_workspace_ephemeral",
             "rotate_workspace_signing_secret",
             "set_workspace_theme",
             "request_dynamic_draft",
             "discard_dynamic_draft",
             "integrate_dynamic_draft",
             "rollback_dynamic_integration",
             "disable_dynamic_live_loader",
             "run_dynamic_draft_trial",
             "run_dynamic_draft_gate",
             "list_dynamic_drafts",
             "show_dynamic_draft",
             "show_dynamic_integration",
             "render_template",
             "validate_template",
             "scaffold_template",
             "create_from_template",
             "signal_link_device",
             "configure_channel_secret",
             "configure_channel_setting",
             "link_channel_identity",
             "unlink_channel_identity",
             "clear_session",
             "sweep_expired_sessions",
             "complete_thread",
             "create_protocol_token",
             "rotate_protocol_token",
             "revoke_protocol_token",
             "ensure_voice_token"
           ]

    assert Registry.duplicate_names() == []
  end

  test "returns the intent-agent action surface without internal actions" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    assert "direct_answer" in agent_action_names
    assert "set_provider_credential" in agent_action_names
    assert "list_channels" in agent_action_names
    assert "show_channel" in agent_action_names
    assert "channel_setup_check" in agent_action_names
    assert "resume_thread_on_channel" in agent_action_names
    assert "list_apps" in agent_action_names
    assert "show_app" in agent_action_names
    assert "list_plugins" in agent_action_names
    assert "show_plugin" in agent_action_names
    assert "generate_image" in agent_action_names
    assert "synthesize_voice" in agent_action_names
    assert "list_marketplace_entries" in agent_action_names
    assert "list_objectives" in agent_action_names
    assert "find_mcp_tools" in agent_action_names
    assert "send_email" in agent_action_names
    assert "send_channel_message" in agent_action_names
    assert "create_calendar_event" in agent_action_names
    assert "install_marketplace_bundle" in agent_action_names
    assert "create_skill" in agent_action_names
    assert "continue_objective" in agent_action_names
    assert "cancel_objective" in agent_action_names
    refute "read" in agent_action_names
    refute "grep" in agent_action_names
    refute "glob" in agent_action_names
    refute "write" in agent_action_names
    refute "edit" in agent_action_names
    refute "bash" in agent_action_names
    refute "whatsapp_doctor" in agent_action_names
    refute "signal_doctor" in agent_action_names
    refute "mcp_doctor_server" in agent_action_names
    refute "mcp_list_tools" in agent_action_names
    refute "mcp_list_resources" in agent_action_names
    refute "mcp_read_resource" in agent_action_names
    refute "mcp_call_tool" in agent_action_names
    refute "marketplace_doctor" in agent_action_names
    refute "security_status" in agent_action_names
    refute "security_review" in agent_action_names
    refute "operator_status" in agent_action_names
    refute "operator_confirmations" in agent_action_names
    refute "operator_events" in agent_action_names
    refute "operator_channels" in agent_action_names
    refute "operator_setting_get" in agent_action_names
    refute "surface_policy_read" in agent_action_names
    refute "surface_policy_update" in agent_action_names
    refute "capture_workspace_voice" in agent_action_names
    refute "transcribe_voice" in agent_action_names
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
             "read",
             "grep",
             "glob",
             "write",
             "edit",
             "bash",
             "start_fanout",
             "whatsapp_doctor",
             "signal_doctor",
             "mcp_doctor_server",
             "mcp_list_tools",
             "mcp_list_resources",
             "mcp_read_resource",
             "mcp_call_tool",
             "mcp_fetch_server_manifest",
             "mcp_evaluate_server",
             "mcp_server_connect",
             "mcp_scan_enable",
             "mcp_scan_pause",
             "mcp_scan_resume",
             "mcp_scan_run_once",
             "find_local_tools",
             "find_tools",
             "discover_patterns",
             "create_self_improvement_draft",
             "discard_self_improvement_draft",
             "promote_skill_draft",
             "promote_workflow_draft",
             "promote_memory_draft",
             "promote_template_draft",
             "promote_objective_draft",
             "promote_capability_gap_draft",
             "validate_skill",
             "run_skill_script",
             "run_package_install",
             "audit_online_skill",
             "import_online_skill",
             "import_remote_skill",
             "import_local_skill",
             "marketplace_doctor",
             "inspect_marketplace_entry",
             "rollback_marketplace_install",
             "list_installed_marketplace_bundles",
             "verify_marketplace_bundle_hash",
             "put_artifact",
             "get_artifact",
             "list_artifacts",
             "artifact_threads",
             "delete_artifact",
             "artifact_doctor",
             "security_status",
             "security_review",
             "sandbox_doctor",
             "build_sandbox_bundle",
             "run_sandbox_command",
             "run_sandbox_gate",
             "discard_sandbox_bundle",
             "operator_status",
             "operator_confirmations",
             "operator_events",
             "operator_channels",
             "operator_setting_get",
             "surface_policy_read",
             "surface_policy_update",
             "settings_doctor",
             "model_doctor",
             "resolved_settings_snapshot",
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
             "capture_workspace_voice",
             "transcribe_voice",
             "voice_local_runtime_doctor",
             "voice_local_runtime_start",
             "record_trace",
             "explain_intent",
             "list_intent_candidates",
             "intent_doctor",
             "intent_list_descriptors",
             "intent_show_descriptor",
             "intent_coverage",
             "intent_eval_run",
             "intent_list_review",
             "optimize_intent_descriptors",
             "promote_intent_descriptor",
             "reindex_intent_descriptors",
             "edit_intent_descriptor",
             "disable_intent_descriptor",
             "enable_intent_descriptor",
             "intent_eval_baseline",
             "intent_eval_capture",
             "intent_eval_add",
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
             "retrieve_active_memory",
             "promote_conversation_turn",
             "sync_app_lesson",
             "show_objective",
             "delegate_agent",
             "list_workflows",
             "inspect_workflow",
             "expand_workflow",
             "start_plan_run",
             "plan_step_confirm",
             "cancel_plan_run",
             "list_plan_runs",
             "registry_health",
             "trace_summary",
             "list_jobs",
             "pause_job",
             "resume_job",
             "run_job",
             "create_job",
             "rename_thread",
             "persist_approval_media_response",
             "first_model_detect",
             "install_ollama",
             "pull_model",
             "serve_health",
             "service_control",
             "restore_database_backup",
             "vault_status",
             "migrate_secrets",
             "apply_persona_profile",
             "manage_workspace_tile",
             "revert_tile_revision",
             "record_workspace_offline_update",
             "dismiss_workspace_ephemeral",
             "rotate_workspace_signing_secret",
             "set_workspace_theme",
             "request_dynamic_draft",
             "discard_dynamic_draft",
             "integrate_dynamic_draft",
             "rollback_dynamic_integration",
             "disable_dynamic_live_loader",
             "run_dynamic_draft_trial",
             "run_dynamic_draft_gate",
             "list_dynamic_drafts",
             "show_dynamic_draft",
             "show_dynamic_integration",
             "render_template",
             "validate_template",
             "scaffold_template",
             "create_from_template",
             "signal_link_device",
             "configure_channel_secret",
             "configure_channel_setting",
             "link_channel_identity",
             "unlink_channel_identity",
             "clear_session",
             "sweep_expired_sessions",
             "complete_thread",
             "create_protocol_token",
             "rotate_protocol_token",
             "revoke_protocol_token",
             "ensure_voice_token"
           ]

    assert {:ok, append_memory} = Registry.capability("append_memory")
    assert append_memory.permission == :memory_write
    assert append_memory.skill_backed?

    assert {:ok, activate_skill} = Registry.capability("activate_skill")
    refute activate_skill.skill_backed?
    assert activate_skill.exposure == :agent

    assert {:ok, create_skill} = Registry.capability("create_skill")
    assert create_skill.permission == :skill_write
    assert create_skill.exposure == :agent
    refute create_skill.skill_backed?

    assert {:ok, list_objectives} = Registry.capability("list_objectives")
    assert list_objectives.permission == :read_only
    assert list_objectives.exposure == :agent
    assert list_objectives.execution_mode == :objectives_read

    assert {:ok, doctor_model_profile} = Registry.capability("doctor_model_profile")
    assert doctor_model_profile.permission == :read_only
    assert doctor_model_profile.exposure == :agent
    assert doctor_model_profile.execution_mode == :settings_read

    assert {:ok, model_doctor} = Registry.capability("model_doctor")
    assert model_doctor.permission == :read_only
    assert model_doctor.exposure == :internal
    assert model_doctor.execution_mode == :settings_read

    assert {:ok, settings_doctor} = Registry.capability("settings_doctor")
    assert settings_doctor.permission == :read_only
    assert settings_doctor.exposure == :internal
    assert settings_doctor.execution_mode == :settings_read

    assert {:ok, doctor_voice_provider} = Registry.capability("doctor_voice_provider")
    assert doctor_voice_provider.permission == :read_only
    assert doctor_voice_provider.exposure == :agent
    assert doctor_voice_provider.execution_mode == :settings_read

    assert {:ok, set_active_model_profile} = Registry.capability("set_active_model_profile")
    assert set_active_model_profile.permission == :settings_write
    assert set_active_model_profile.exposure == :agent
    assert set_active_model_profile.execution_mode == :settings_write

    assert {:ok, resume_thread_on_channel} = Registry.capability("resume_thread_on_channel")
    assert resume_thread_on_channel.permission == :conversation_write
    assert resume_thread_on_channel.exposure == :agent
    assert resume_thread_on_channel.execution_mode == :conversation_resume

    assert {:ok, mcp_doctor_server} = Registry.capability("mcp_doctor_server")
    assert mcp_doctor_server.permission == :read_only
    assert mcp_doctor_server.exposure == :internal
    assert mcp_doctor_server.execution_mode == :mcp_doctor

    assert {:ok, mcp_list_tools} = Registry.capability("mcp_list_tools")
    assert mcp_list_tools.execution_mode == :mcp_discovery

    assert {:ok, mcp_read_resource} = Registry.capability("mcp_read_resource")
    assert mcp_read_resource.permission == :mcp_resource_read
    assert mcp_read_resource.execution_mode == :mcp_resource_read
    assert mcp_read_resource.resumable?

    assert {:ok, mcp_call_tool} = Registry.capability("mcp_call_tool")
    assert mcp_call_tool.permission == :mcp_tool_call
    assert mcp_call_tool.execution_mode == :mcp_tool_call
    assert mcp_call_tool.resumable?

    assert {:ok, coding_read} = Registry.capability("read")
    assert coding_read.permission == :coding_file_read
    assert coding_read.exposure == :internal
    assert coding_read.execution_mode == :coding_file_read

    assert {:ok, coding_grep} = Registry.capability("grep")
    assert coding_grep.permission == :coding_file_read
    assert coding_grep.exposure == :internal
    assert coding_grep.execution_mode == :coding_search

    assert {:ok, coding_glob} = Registry.capability("glob")
    assert coding_glob.permission == :coding_file_read
    assert coding_glob.exposure == :internal
    assert coding_glob.execution_mode == :coding_search

    assert {:ok, find_mcp_tools} = Registry.capability("find_mcp_tools")
    assert find_mcp_tools.permission == :tool_discovery
    assert find_mcp_tools.exposure == :agent
    assert find_mcp_tools.execution_mode == :mcp_discovery

    assert {:ok, mcp_fetch_server_manifest} = Registry.capability("mcp_fetch_server_manifest")
    assert mcp_fetch_server_manifest.permission == :tool_discovery
    assert mcp_fetch_server_manifest.execution_mode == :mcp_discovery

    assert {:ok, mcp_evaluate_server} = Registry.capability("mcp_evaluate_server")
    assert mcp_evaluate_server.permission == :tool_discovery
    assert mcp_evaluate_server.execution_mode == :mcp_discovery

    assert {:ok, mcp_server_connect} = Registry.capability("mcp_server_connect")
    assert mcp_server_connect.permission == :mcp_server_connect
    assert mcp_server_connect.execution_mode == :mcp_server_connect
    assert mcp_server_connect.resumable?

    assert {:ok, marketplace_doctor} = Registry.capability("marketplace_doctor")
    assert marketplace_doctor.permission == :read_only
    assert marketplace_doctor.exposure == :internal
    assert marketplace_doctor.execution_mode == :marketplace_diagnostic

    assert {:ok, install_marketplace_bundle} = Registry.capability("install_marketplace_bundle")
    assert install_marketplace_bundle.permission == :marketplace_install
    assert install_marketplace_bundle.execution_mode == :marketplace_install_bundle
    assert install_marketplace_bundle.resumable?

    assert {:ok, rollback_marketplace_install} =
             Registry.capability("rollback_marketplace_install")

    assert rollback_marketplace_install.permission == :marketplace_install
    assert rollback_marketplace_install.execution_mode == :marketplace_rollback
    assert rollback_marketplace_install.resumable?

    assert {:ok, verify_marketplace_bundle_hash} =
             Registry.capability("verify_marketplace_bundle_hash")

    assert verify_marketplace_bundle_hash.permission == :read_only
    assert verify_marketplace_bundle_hash.execution_mode == :marketplace_browse

    assert {:ok, put_artifact} = Registry.capability("put_artifact")
    assert put_artifact.permission == :artifact_write
    assert put_artifact.exposure == :internal
    assert put_artifact.execution_mode == :artifact_write

    assert {:ok, artifact_threads} = Registry.capability("artifact_threads")
    assert artifact_threads.permission == :artifact_read
    assert artifact_threads.exposure == :internal
    assert artifact_threads.execution_mode == :artifact_read

    assert {:ok, delete_artifact} = Registry.capability("delete_artifact")
    assert delete_artifact.permission == :artifact_delete
    assert delete_artifact.confirmation == :required
    assert delete_artifact.resumable?

    assert {:ok, find_local_tools} = Registry.capability("find_local_tools")
    assert find_local_tools.permission == :read_only
    assert find_local_tools.exposure == :internal
    assert find_local_tools.execution_mode == :mcp_discovery

    assert {:ok, find_tools} = Registry.capability("find_tools")
    assert find_tools.permission == :read_only
    assert find_tools.exposure == :internal
    assert find_tools.execution_mode == :mcp_discovery

    assert {:ok, cancel_objective} = Registry.capability("cancel_objective")
    assert cancel_objective.permission == :objective_write
    assert cancel_objective.exposure == :agent
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

    for name <- ["write", "edit"] do
      assert {:ok, coding_file_effect} = Registry.capability(name)
      assert coding_file_effect.permission == :coding_file_write
      assert coding_file_effect.exposure == :internal
      assert coding_file_effect.execution_mode == :coding_file_write
      assert coding_file_effect.confirmation == :required
      assert coding_file_effect.resumable?
    end

    assert {:ok, bash} = Registry.capability("bash")
    assert bash.permission == :coding_shell_execute
    assert bash.exposure == :internal
    assert bash.execution_mode == :coding_shell_execute
    assert bash.confirmation == :required
    assert bash.resumable?

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

    assert {:ok, integrate_dynamic_draft} = Registry.capability("integrate_dynamic_draft")
    assert integrate_dynamic_draft.permission == :dynamic_integration
    assert integrate_dynamic_draft.execution_mode == :dynamic_loader
    assert integrate_dynamic_draft.exposure == :internal
    assert integrate_dynamic_draft.confirmation == :required
    assert integrate_dynamic_draft.resumable?

    assert {:ok, request_dynamic_draft} = Registry.capability("request_dynamic_draft")
    assert request_dynamic_draft.permission == :dynamic_codegen_request
    assert request_dynamic_draft.execution_mode == :dynamic_codegen
    assert request_dynamic_draft.exposure == :internal
    assert request_dynamic_draft.confirmation == :not_required

    assert {:ok, discard_dynamic_draft} = Registry.capability("discard_dynamic_draft")
    assert discard_dynamic_draft.permission == :dynamic_codegen_discard
    assert discard_dynamic_draft.execution_mode == :dynamic_codegen_discard
    assert discard_dynamic_draft.exposure == :internal
    assert discard_dynamic_draft.confirmation == :not_required

    assert {:ok, render_template} = Registry.capability("render_template")
    assert render_template.permission == :read_only
    assert render_template.execution_mode == :template_render

    assert {:ok, validate_template} = Registry.capability("validate_template")
    assert validate_template.permission == :read_only
    assert validate_template.execution_mode == :template_validate

    assert {:ok, scaffold_template} = Registry.capability("scaffold_template")
    assert scaffold_template.permission == :skill_write
    assert scaffold_template.execution_mode == :template_scaffold

    assert {:ok, create_from_template} = Registry.capability("create_from_template")
    assert create_from_template.permission == :dynamic_codegen_request
    assert create_from_template.execution_mode == :template_dynamic_draft

    assert {:ok, promote_template_draft} = Registry.capability("promote_template_draft")
    assert promote_template_draft.permission == :dynamic_codegen_request
    assert promote_template_draft.execution_mode == :template_dynamic_draft
    assert promote_template_draft.confirmation == :not_required

    assert {:ok, promote_objective_draft} = Registry.capability("promote_objective_draft")
    assert promote_objective_draft.permission == :objective_write
    assert promote_objective_draft.execution_mode == :objective_draft_promotion
    assert promote_objective_draft.confirmation == :required

    assert {:ok, promote_capability_gap_draft} =
             Registry.capability("promote_capability_gap_draft")

    assert promote_capability_gap_draft.permission == :dynamic_codegen_request
    assert promote_capability_gap_draft.execution_mode == :dynamic_codegen
    assert promote_capability_gap_draft.confirmation == :not_required

    assert {:ok, rollback_dynamic_integration} =
             Registry.capability("rollback_dynamic_integration")

    assert rollback_dynamic_integration.permission == :dynamic_integration
    assert rollback_dynamic_integration.resumable?

    assert {:ok, disable_dynamic_live_loader} =
             Registry.capability("disable_dynamic_live_loader")

    assert disable_dynamic_live_loader.permission == :settings_write
    assert disable_dynamic_live_loader.confirmation == :not_required

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

    assert {:ok, deny_confirmation} = Registry.capability("deny_confirmation")
    assert deny_confirmation.permission == :confirmation_decide
    assert deny_confirmation.exposure == :internal

    assert {:ok, get_public_call_result} = Registry.capability("get_public_call_result")
    assert get_public_call_result.permission == :read_only
    assert get_public_call_result.execution_mode == :read_only
    assert get_public_call_result.exposure == :agent
    assert get_public_call_result.confirmation == :not_required

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

    assert {:ok, resolved_settings_snapshot} = Registry.capability("resolved_settings_snapshot")
    assert resolved_settings_snapshot.permission == :read_only
    assert resolved_settings_snapshot.execution_mode == :settings_read
    assert resolved_settings_snapshot.exposure == :internal
    assert resolved_settings_snapshot.confirmation == :not_required

    assert {:ok, capture_workspace_voice} = Registry.capability("capture_workspace_voice")
    assert capture_workspace_voice.permission == :microphone_capture
    assert capture_workspace_voice.exposure == :internal
    assert capture_workspace_voice.execution_mode == :live_microphone_capture
    assert capture_workspace_voice.resumable? == true

    assert {:ok, transcribe_voice} = Registry.capability("transcribe_voice")
    assert transcribe_voice.permission == :voice_transcribe
    assert transcribe_voice.exposure == :internal
    assert transcribe_voice.execution_mode == :voice_provider_call
    assert transcribe_voice.resumable? == true

    assert {:ok, synthesize_voice} = Registry.capability("synthesize_voice")
    assert synthesize_voice.permission == :voice_synthesize
    assert synthesize_voice.exposure == :agent
    assert synthesize_voice.execution_mode == :voice_provider_call
    assert synthesize_voice.resumable? == true

    assert {:ok, generate_image} = Registry.capability("generate_image")
    assert generate_image.permission == :image_generate
    assert generate_image.exposure == :agent
    assert generate_image.execution_mode == :image_provider_call
    assert generate_image.resumable? == true

    assert {:ok, voice_local_runtime_doctor} =
             Registry.capability("voice_local_runtime_doctor")

    assert voice_local_runtime_doctor.permission == :read_only
    assert voice_local_runtime_doctor.exposure == :internal
    assert voice_local_runtime_doctor.execution_mode == :settings_read

    assert {:ok, voice_local_runtime_start} = Registry.capability("voice_local_runtime_start")
    assert voice_local_runtime_start.permission == :voice_local_runtime_manage
    assert voice_local_runtime_start.exposure == :internal
    assert voice_local_runtime_start.execution_mode == :voice_local_runtime

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
    assert Registry.resumable?("integrate_dynamic_draft")
    assert Registry.resumable?("rollback_dynamic_integration")
    assert Registry.resumable?("mcp_read_resource")
    assert Registry.resumable?("mcp_call_tool")
    assert Registry.resumable?("capture_workspace_voice")
    assert Registry.resumable?("transcribe_voice")
    assert Registry.resumable?("start_fanout")
    assert Registry.resumable?("synthesize_voice")
    assert Registry.resumable?("generate_image")
    assert Registry.resumable?("write")
    assert Registry.resumable?("edit")
    assert Registry.resumable?("bash")

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

  test "app and plugin registration emit lifecycle and action registry signals" do
    on_exit(fn -> AllbertAssist.App.Registry.unregister(:action_tagging_app) end)

    assert {:ok, _app_subscription} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.app.**")

    assert {:ok, _plugin_subscription} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.plugin.**")

    assert {:ok, _action_subscription} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.action.registry_changed")

    assert {:ok, :action_tagging_app} = AllbertAssist.App.Registry.register(ActionTaggingApp)

    assert_receive {:signal, %{type: "allbert.app.registered"} = app_signal}, 1_000
    assert app_signal.data.app_id == :action_tagging_app
    assert app_signal.data.action_names == ["direct_answer"]

    assert_receive {:signal, %{type: "allbert.action.registry_changed"} = action_signal},
                   1_000

    assert action_signal.data.reason == :app_registered
    assert action_signal.data.app_id == :action_tagging_app

    assert {:ok, "example.signals"} =
             PluginRegistry.register_entry(%PluginEntry{
               plugin_id: "example.signals",
               display_name: "Example Signals",
               version: "0.1.0",
               kind: "actions",
               source: :project,
               status: :enabled,
               trust_status: :trusted,
               actions: [PluginEcho]
             })

    assert_receive {:signal, %{type: "allbert.plugin.registered"} = plugin_signal}, 1_000
    assert plugin_signal.data.plugin_id == "example.signals"
    assert plugin_signal.data.action_names == ["plugin_echo"]

    assert_receive {:signal, %{type: "allbert.action.registry_changed"} = plugin_action_signal},
                   1_000

    assert plugin_action_signal.data.reason == :plugin_registered
    assert plugin_action_signal.data.plugin_id == "example.signals"
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
