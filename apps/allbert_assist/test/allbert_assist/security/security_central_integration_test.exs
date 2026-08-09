defmodule AllbertAssist.SecurityCentralIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Security
  alias AllbertAssist.Security.Context
  alias AllbertAssist.Security.Decision
  alias AllbertAssist.Settings

  # These two rows assert Security Central against residual runtime rather than
  # against its own contracts: one loads skill trust through the Skills
  # registry, the other renders operator status from fully resolved settings.
  # Stubbing either would leave the row asserting the stub, so both stay here.

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
      Decision.compatibility(decision, source: AllbertAssist.Security)

    assert Map.keys(compatibility) |> Enum.sort() ==
             [:decision, :permission, :reason, :requires_confirmation, :source]

    assert compatibility.source == AllbertAssist.Security
  end

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
