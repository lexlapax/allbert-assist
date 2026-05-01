defmodule AllbertAssist.Security.PermissionGateTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Security.PermissionGate

  test "documents the v0.01 permission classes" do
    assert PermissionGate.permission_classes() == [
             :read_only,
             :memory_write,
             :command_plan,
             :command_execute,
             :external_network
           ]
  end

  test "allows read-only, memory-write intent, and command planning" do
    for permission <- [:read_only, :memory_write, :command_plan] do
      decision = PermissionGate.authorize(permission, %{})

      assert decision.permission == permission
      assert decision.decision == :allowed
      refute decision.requires_confirmation
      assert PermissionGate.allowed?(decision)
      assert PermissionGate.response_status(decision) == :completed
    end
  end

  test "denies command execution" do
    decision = PermissionGate.authorize(:command_execute, %{})

    assert decision.permission == :command_execute
    assert decision.decision == :denied
    refute decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :denied
  end

  test "requires confirmation for external network access" do
    decision = PermissionGate.authorize(:external_network, %{})

    assert decision.permission == :external_network
    assert decision.decision == :needs_confirmation
    assert decision.requires_confirmation
    refute PermissionGate.allowed?(decision)
    assert PermissionGate.response_status(decision) == :needs_confirmation
  end
end
