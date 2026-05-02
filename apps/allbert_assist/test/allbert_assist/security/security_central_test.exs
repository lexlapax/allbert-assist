defmodule AllbertAssist.SecurityCentralTest do
  use ExUnit.Case, async: false

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

    :ok
  end

  test "normalizes sparse runtime context" do
    context =
      Context.normalize(:read_only, %{
        request: %{operator_id: "local", channel: :cli, input_signal_id: "sig"},
        selected_action: "direct_answer",
        selected_skill: "append-memory",
        skill_metadata: %{source_scope: :built_in, trust_status: :trusted},
        api_key: "sk-test"
      })

    assert context.actor.id == "local"
    assert context.channel == %{name: :cli, trust: :local}
    assert context.session.source_signal_id == "sig"
    assert context.action.name == "direct_answer"
    assert context.action.registered?
    assert context.skill.name == "append-memory"
    assert context.skill.trust_status == :trusted
    assert context.secret_status.raw_secret_present?
  end

  test "classifies risk by permission" do
    assert Risk.classify(:read_only).tier == :minimal
    assert Risk.classify(:memory_write).tier == :low
    assert Risk.classify(:settings_write).tier == :medium
    assert Risk.classify(:external_network).tier == :high
    assert Risk.classify(:settings_secret_read).tier == :critical
    assert Risk.classify(:unknown_permission).tier == :critical
  end

  test "resolves policy with built-in safety floors" do
    assert Policy.resolve(:read_only).effective == :allowed
    assert Policy.resolve(:memory_write).effective == :allowed
    assert Policy.resolve(:command_plan).effective == :allowed
    assert Policy.resolve(:command_execute).effective == :denied
    assert Policy.resolve(:external_network).effective == :needs_confirmation
    assert Policy.resolve(:settings_secret_read).effective == :denied
    assert Policy.resolve(:unknown_permission).effective == :denied
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
    assert Enum.any?(status.safety_floors, &(&1.permission == :unknown and &1.floor == :denied))
    assert status.secret_status.providers >= 1
    assert status.redaction_posture.secret_ref_display == "[SECRET_REF]"
    assert Enum.any?(status.future_boundaries, &(&1.name == :shell_sandbox))
    refute inspect(status) =~ "secret://"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
