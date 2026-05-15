defmodule AllbertAssist.Security.PermissionGateTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Security.PermissionGate

  test "documents the runtime permission classes" do
    assert PermissionGate.permission_classes() == [
             :read_only,
             :memory_write,
             :command_plan,
             :command_execute,
             :external_network,
             :package_install,
             :online_skill_import,
             :settings_write,
             :skill_write,
             :skill_script_execute,
             :confirmation_decide,
             :stocksage_write,
             :settings_secret_write,
             :settings_secret_read
           ]
  end

  test "allows read-only, memory-write intent, command planning, and StockSage local writes" do
    for permission <- [:read_only, :memory_write, :command_plan, :stocksage_write] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.permission == permission
      assert decision.decision == :allowed
      refute decision.requires_confirmation
      assert PermissionGate.allowed?(decision)
      assert PermissionGate.response_status(decision) == :completed
      assert_compatibility_fields(decision)
    end
  end

  test "denies command execution" do
    decision = PermissionGate.authorize(:command_execute, %{})

    assert decision.permission == :command_execute
    assert decision.decision == :denied
    refute decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :denied
    assert_compatibility_fields(decision)
  end

  test "requires confirmation for external network access" do
    decision = PermissionGate.authorize(:external_network, %{})

    assert decision.permission == :external_network
    assert decision.decision == :needs_confirmation
    assert decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :needs_confirmation
    assert_compatibility_fields(decision)
  end

  test "denies skill script execution until explicitly enabled" do
    decision = PermissionGate.authorize(:skill_script_execute, %{})

    assert decision.permission == :skill_script_execute
    assert decision.decision == :denied
    refute decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :denied
    assert_compatibility_fields(decision)
  end

  test "denies new v0.10 high-risk boundaries until explicitly enabled" do
    for permission <- [:package_install, :online_skill_import] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.permission == permission
      assert decision.decision == :denied
      refute decision.requires_confirmation
      refute PermissionGate.allowed?(decision)
      assert PermissionGate.response_status(decision) == :denied
      assert_compatibility_fields(decision)
    end
  end

  test "allows safe settings writes, skill scaffolds, confirmation decisions, and explicit secret writes" do
    for permission <- [
          :settings_write,
          :skill_write,
          :confirmation_decide,
          :settings_secret_write
        ] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.permission == permission
      assert decision.decision == :allowed
      assert PermissionGate.allowed?(decision)
      assert_compatibility_fields(decision)
    end
  end

  test "denies raw user-facing secret reads" do
    decision = PermissionGate.authorize(:settings_secret_read, %{})

    assert decision.permission == :settings_secret_read
    assert decision.decision == :denied
    refute PermissionGate.allowed?(decision)
    assert_compatibility_fields(decision)
  end

  test "denies unknown permission classes with compatibility fields" do
    decision = PermissionGate.authorize(:unknown_future_permission, %{request: %{channel: :test}})

    assert decision.permission == :unknown_future_permission
    assert decision.decision == :denied
    refute decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :denied
    assert decision.reason =~ "Unknown permission class"
    assert_compatibility_fields(decision)
  end

  test "delegates to Security Central and preserves widened decision metadata" do
    decision =
      PermissionGate.authorize(:external_network, %{
        request: %{operator_id: "local", channel: :test, input_signal_id: "sig"},
        selected_action: "external_network_request"
      })

    assert decision.source == PermissionGate
    assert decision.risk.tier == :high
    assert decision.policy.effective == :needs_confirmation
    assert decision.trace.risk_tier == :high
    assert decision.audit.event == "security.decision"
    assert decision.context.actor.id == "local"
    assert decision.trust_boundary.action_registered?
  end

  defp assert_compatibility_fields(decision) do
    for field <- [:permission, :decision, :reason, :requires_confirmation, :source] do
      assert Map.has_key?(decision, field)
    end

    assert is_binary(decision.reason)
    assert is_boolean(decision.requires_confirmation)
    assert is_atom(decision.source)
  end
end
