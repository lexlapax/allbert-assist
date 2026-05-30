defmodule AllbertAssist.SecurityCentralTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security
  alias AllbertAssist.Security.Context
  alias AllbertAssist.Security.Decision
  alias AllbertAssist.Security.Policy
  alias AllbertAssist.Security.Redactor
  alias AllbertAssist.Security.Risk
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-security-central-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: root)

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "normalizes sparse runtime context" do
    assert {:ok, capability} = Registry.capability("append_memory")

    context =
      Context.normalize(:read_only, %{
        request: %{operator_id: "local", channel: :cli, input_signal_id: "sig"},
        selected_action: "append_memory",
        action_capability: Map.from_struct(capability),
        selected_skill: "append-memory",
        skill_metadata: %{source_scope: :built_in, trust_status: :trusted},
        api_key: "sk-test"
      })

    assert context.actor.id == "local"
    assert context.channel == %{name: :cli, trust: :local}
    assert context.session.source_signal_id == "sig"
    assert context.action.name == "append_memory"
    assert context.action.registered?
    assert context.action.capability.name == "append_memory"
    assert context.skill.name == "append-memory"
    assert context.skill.trust_status == :trusted
    assert context.skill.capability_contract.validation_status == :valid
    assert context.skill.capability_contract.execution_eligible?
    assert context.secret_status.raw_secret_present?
  end

  test "loads selected skill trust and provenance from the registry", %{root: root} do
    built_in_root = Path.join(root, "built-in-skills")
    write_skill(built_in_root, "trusted-helper", "trusted-helper")

    context =
      Context.normalize(:read_only, %{
        built_in_root: built_in_root,
        selected_skill: "trusted-helper"
      })

    assert context.skill.name == "trusted-helper"
    assert context.skill.source_scope == :built_in
    assert context.skill.trust_status == :trusted
    assert context.skill.lookup_status == :found
  end

  test "classifies risk by permission" do
    assert Risk.classify(:read_only).tier == :minimal
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
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "permissions" => %{
                 "memory_write" => "denied",
                 "command_execute" => "allowed",
                 "skill_script_execute" => "allowed",
                 "dynamic_integration" => "denied",
                 "package_install" => "allowed",
                 "online_skill_import" => "allowed",
                 "tool_discovery" => "denied",
                 "mcp_server_connect" => "needs_confirmation"
               }
             })

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

  test "unknown actions and undiscoverable selected skills deny instead of gaining authority" do
    unknown_action =
      Security.authorize(:read_only, %{
        selected_action: "not_registered"
      })

    assert unknown_action.decision == :denied
    assert unknown_action.policy.context_denial =~ "Unknown or unregistered action"

    missing_skill =
      Security.authorize(:memory_write, %{
        selected_skill: "missing-skill",
        selected_action: "append_memory"
      })

    assert missing_skill.decision == :denied
    assert missing_skill.policy.context_denial =~ "Selected skill is not trusted"
  end

  test "builds canonical decisions with compatibility and widened metadata" do
    decision =
      Security.authorize(:external_network, %{
        request: %{operator_id: "local", channel: :test, input_signal_id: "sig"},
        selected_action: "external_network_request"
      })

    assert decision.permission == :external_network
    assert decision.decision == :needs_confirmation
    assert decision.requires_confirmation
    assert decision.risk.tier == :high
    assert decision.policy.effective == :needs_confirmation
    assert decision.trace.risk_tier == :high
    assert decision.audit.event == "security.decision"
    assert decision.context.actor.id == "local"
    assert decision.trust_boundary.action_registered?

    compatibility =
      Decision.compatibility(decision, source: AllbertAssist.Security.PermissionGate)

    assert Map.keys(compatibility) |> Enum.sort() ==
             [:decision, :permission, :reason, :requires_confirmation, :source]

    assert compatibility.source == AllbertAssist.Security.PermissionGate
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

  test "returns redacted operator security status" do
    status = Security.status(%{request: %{operator_id: "local", channel: :test}})

    assert Enum.any?(status.permission_defaults, &(&1.permission == :command_execute))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :package_install))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :online_skill_import))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :skill_write))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :dynamic_codegen_request))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :dynamic_codegen_discard))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :skill_script_execute))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :confirmation_decide))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :tool_discovery))
    assert Enum.any?(status.permission_defaults, &(&1.permission == :mcp_server_connect))
    assert Enum.any?(status.safety_floors, &(&1.permission == :unknown and &1.floor == :denied))
    assert status.secret_status.providers >= 1
    assert status.redaction_posture.secret_ref_display == "[SECRET_REF]"
    assert Enum.any?(status.future_boundaries, &(&1.name == :shell_sandbox))

    assert Enum.any?(
             status.future_boundaries,
             &(&1.name == :external_adapters_and_imports and &1.status == :implemented)
           )

    assert status.capability_boundaries.external_services.enabled == false
    assert status.capability_boundaries.package_installs.allowed_managers == ["npm"]
    assert status.capability_boundaries.online_skill_import.allowed_sources == ["skills_sh"]
    refute inspect(status) =~ "secret://"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp write_skill(root, directory, name) do
    skill_root = Path.join(root, directory)
    File.mkdir_p!(skill_root)

    File.write!(Path.join(skill_root, "SKILL.md"), """
    ---
    name: #{name}
    description: #{name} test skill.
    ---

    ## Workflow

    Inspect only.
    """)
  end
end
