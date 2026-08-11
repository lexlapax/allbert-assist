defmodule AllbertAssist.SecurityCentralTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Kernel.Contract.TestProviders
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Security.Risk

  # Security Central reads posture through the kernel settings contract, so a
  # row states the operator values it needs instead of writing them into a
  # temporary Allbert Home.
  setup do
    on_exit(TestProviders.stub_settings!(%{}))
    :ok
  end

  test "classifies risk by permission" do
    assert Risk.classify(:read_only).tier == :minimal
    assert Risk.classify(:memory_propose).tier == :minimal
    assert Risk.classify(:memory_write).tier == :low
    assert Risk.classify(:settings_write).tier == :medium
    assert Risk.classify(:skill_write).tier == :medium
    assert Risk.classify(:dynamic_codegen_request).tier == :medium
    assert Risk.classify(:dynamic_codegen_discard).tier == :medium
    assert Risk.classify(:confirmation_decide).tier == :medium
    assert Risk.classify(:objective_write).tier == :low
    assert Risk.classify(:workspace_canvas_write).tier == :low
    assert Risk.classify(:dynamic_integration).tier == :critical
    assert Risk.classify(:stocksage_write).tier == :low
    assert Risk.classify(:skill_script_execute).tier == :high
    assert Risk.classify(:tool_discovery).tier == :medium
    assert Risk.classify(:mcp_server_connect).tier == :high
    assert Risk.classify(:mcp_tool_call).tier == :high
    assert Risk.classify(:mcp_resource_read).tier == :medium
    assert Risk.classify(:external_network).tier == :high
    assert Risk.classify(:package_install).tier == :high
    assert Risk.classify(:online_skill_import).tier == :high
    assert Risk.classify(:settings_secret_read).tier == :critical
    assert Risk.classify(:unknown_permission).tier == :critical
  end

  test "resolves policy with built-in safety floors" do
    assert Policy.resolve(:read_only).effective == :allowed
    assert Policy.resolve(:memory_propose).effective == :allowed
    assert Policy.resolve(:memory_write).effective == :allowed
    assert Policy.resolve(:command_plan).effective == :allowed
    assert Policy.resolve(:command_execute).effective == :denied
    assert Policy.resolve(:external_network).effective == :needs_confirmation
    assert Policy.resolve(:package_install).effective == :denied
    assert Policy.resolve(:online_skill_import).effective == :denied
    assert Policy.resolve(:skill_write).effective == :allowed
    assert Policy.resolve(:dynamic_codegen_request).effective == :allowed
    assert Policy.resolve(:dynamic_codegen_discard).effective == :allowed
    assert Policy.resolve(:skill_script_execute).effective == :denied
    assert Policy.resolve(:confirmation_decide).effective == :allowed
    assert Policy.resolve(:objective_write).effective == :allowed
    assert Policy.resolve(:workspace_canvas_write).effective == :allowed
    assert Policy.resolve(:dynamic_integration).effective == :needs_confirmation
    assert Policy.resolve(:stocksage_write).effective == :allowed
    assert Policy.resolve(:tool_discovery).effective == :allowed
    assert Policy.resolve(:mcp_server_connect).effective == :needs_confirmation
    assert Policy.resolve(:mcp_tool_call).effective == :needs_confirmation
    assert Policy.resolve(:mcp_resource_read).effective == :allowed
    assert Policy.resolve(:settings_secret_read).effective == :denied
    assert Policy.resolve(:unknown_permission).effective == :denied
  end

  test "settings can tighten policy but cannot bypass safety floors" do
    on_exit(
      TestProviders.stub_settings!(%{
        "permissions.memory_propose" => "denied",
        "permissions.memory_write" => "denied",
        "permissions.command_execute" => "allowed",
        "permissions.skill_script_execute" => "allowed",
        "permissions.dynamic_integration" => "denied",
        "permissions.package_install" => "allowed",
        "permissions.online_skill_import" => "allowed",
        "permissions.tool_discovery" => "denied",
        "permissions.mcp_server_connect" => "needs_confirmation"
      })
    )

    proposal_policy = Policy.resolve(:memory_propose)
    assert proposal_policy.configured == "denied"
    assert proposal_policy.effective == :denied

    memory_policy = Policy.resolve(:memory_write)
    assert memory_policy.configured == "denied"
    assert memory_policy.effective == :denied
    assert memory_policy.source == :settings

    command_policy = Policy.resolve(:command_execute)
    assert command_policy.configured == "allowed"
    assert command_policy.configured_decision == :allowed
    assert command_policy.effective == :needs_confirmation
    assert command_policy.capped?

    script_policy = Policy.resolve(:skill_script_execute)
    assert script_policy.configured == "allowed"
    assert script_policy.configured_decision == :allowed
    assert script_policy.effective == :needs_confirmation
    assert script_policy.capped?

    dynamic_policy = Policy.resolve(:dynamic_integration)
    assert dynamic_policy.configured == "denied"
    assert dynamic_policy.effective == :denied

    package_policy = Policy.resolve(:package_install)
    assert package_policy.configured == "allowed"
    assert package_policy.configured_decision == :allowed
    assert package_policy.effective == :needs_confirmation
    assert package_policy.capped?

    import_policy = Policy.resolve(:online_skill_import)
    assert import_policy.configured == "allowed"
    assert import_policy.configured_decision == :allowed
    assert import_policy.effective == :needs_confirmation
    assert import_policy.capped?

    discovery_policy = Policy.resolve(:tool_discovery)
    assert discovery_policy.configured == "denied"
    assert discovery_policy.effective == :denied

    connect_policy = Policy.resolve(:mcp_server_connect)
    assert connect_policy.configured == "needs_confirmation"
    assert connect_policy.effective == :needs_confirmation
  end

  test "redacts sensitive values and secret references" do
    redacted =
      Redactor.redact(%{
        api_key: "sk-test",
        provider_ref: "secret://providers/openai/api_key",
        nested: [%{password: "pw"}, %{safe: "visible"}]
      })

    assert redacted.api_key == "[REDACTED]"
    assert redacted.provider_ref == "[SECRET_REF]"
    assert [%{password: "[REDACTED]"}, %{safe: "visible"}] = redacted.nested
  end
end
