defmodule AllbertAssist.Runtime.ResponseIntentValuesTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Runtime.Response

  # Response renders intent decisions and approval handoffs through the kernel
  # ResponseValues contract, and the struct path deliberately renders
  # differently from a plain map. Proving that needs the real structs, so this
  # row stays with the residual that owns them; stubbing the contract would
  # leave it asserting the stub.

  test "normalizes map responses while preserving extra payload keys" do
    handoff = %ApprovalHandoff{confirmation_id: "conf_1", status: :pending}

    response =
      Response.normalize(%{
        "message" => "Ready.",
        "status" => "needs_confirmation",
        decision: %Decision{intent: :answer, diagnostics: [%{source: :decision}]},
        approval_handoff: handoff,
        custom: %{kept?: true}
      })

    assert response.message == "Ready."
    assert response.status == :needs_confirmation
    assert response.actions == []
    assert response.custom == %{kept?: true}
    assert response.decision.intent == :answer
    assert response.approval_handoff.confirmation_id == "conf_1"
    assert response.diagnostics == [%{source: :decision}]
  end
end
