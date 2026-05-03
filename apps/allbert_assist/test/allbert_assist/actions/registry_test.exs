defmodule AllbertAssist.Actions.RegistryTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Multiply
  alias AllbertAssist.Actions.Registry

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
             "validate_skill",
             "create_skill",
             "run_skill_script",
             "run_package_install",
             "audit_online_skill",
             "import_online_skill",
             "security_status",
             "list_confirmations",
             "show_confirmation",
             "approve_confirmation",
             "deny_confirmation",
             "expire_confirmations",
             "list_resource_grants",
             "show_resource_grant",
             "revoke_resource_grant",
             "remember_resource_grant",
             "record_trace"
           ]

    assert Registry.duplicate_names() == []
  end

  test "returns the intent-agent action surface without internal actions" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    assert "direct_answer" in agent_action_names
    assert "set_provider_credential" in agent_action_names
    refute "security_status" in agent_action_names
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
             "security_status",
             "list_confirmations",
             "show_confirmation",
             "approve_confirmation",
             "deny_confirmation",
             "expire_confirmations",
             "list_resource_grants",
             "show_resource_grant",
             "revoke_resource_grant",
             "remember_resource_grant",
             "record_trace"
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

    assert {:ok, search_online_skills} = Registry.capability("search_online_skills")
    assert search_online_skills.permission == :external_network
    assert search_online_skills.execution_mode == :online_skill_search
    assert search_online_skills.resumable?

    assert {:ok, import_online_skill} = Registry.capability("import_online_skill")
    assert import_online_skill.permission == :online_skill_import
    assert import_online_skill.confirmation == :required
    assert import_online_skill.resumable?

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

    assert {:error, {:unknown_action, "missing_action"}} = Registry.capability("missing_action")
  end

  test "reports resumable targets from capability metadata" do
    assert Registry.resumable?("external_network_request")
    assert Registry.resumable?(:run_shell_command)
    assert Registry.resumable?("run_package_install")
    assert Registry.resumable?("search_online_skills")
    assert Registry.resumable?("import_online_skill")
    assert Registry.resumable?("run_skill_script")

    refute Registry.resumable?("direct_answer")
    refute Registry.resumable?("plan_package_install")
    refute Registry.resumable?("missing_action")
  end

  test "resolves registered actions by name and module only" do
    assert {:ok, DirectAnswer} = Registry.resolve("direct_answer")
    assert {:ok, DirectAnswer} = Registry.resolve(:direct_answer)
    assert {:ok, DirectAnswer} = Registry.resolve(DirectAnswer)

    assert {:error, {:unknown_action, "missing_action"}} = Registry.resolve("missing_action")
    assert {:error, {:unknown_action, Multiply}} = Registry.resolve(Multiply)
    refute Registry.registered_module?(Multiply)
  end
end
