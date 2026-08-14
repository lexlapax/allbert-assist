defmodule AllbertAssist.Security.PermissionGateIntegrationTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Security

  # This row resolves a shipped action by name, so it needs the real catalog.
  # The M7.1 closure gate scans module references and cannot see an action
  # named by string, which is why the split missed it until the kernel suite
  # ran without the pack.

  test "delegates to Security Central and preserves widened decision metadata" do
    decision =
      Security.authorize(:external_network, %{
        request: %{operator_id: "local", channel: :test, input_signal_id: "sig"},
        selected_action: "external_network_request"
      })

    assert decision.source == Security
    assert decision.risk.tier == :high
    assert decision.policy.effective == :needs_confirmation
    assert decision.trace.risk_tier == :high
    assert decision.audit.event == "security.decision"
    assert decision.context.actor.id == "local"
    assert decision.trust_boundary.action_registered?
  end
end
