defmodule AllbertAssist.Runtime.ResponseTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.ApprovalHandoff
  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Runtime.Response

  test "builders cover the shared runtime status vocabulary" do
    assert Response.completed("done").status == :completed
    assert Response.needs_confirmation("confirm").status == :needs_confirmation
    assert Response.confirmation_needed("confirm").status == :needs_confirmation
    assert Response.denied("no").status == :denied
    assert Response.advisory("consider").status == :advisory
    assert Response.error("broken", :boom).status == :error
    assert Response.unsupported("not yet", :missing_capability).status == :unsupported
    assert Response.unavailable("offline", :bridge_disabled).status == :unavailable
  end

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

  test "normalizes action callback errors and invalid results" do
    error = Response.from_action_result({:error, :boom}, "example_action")
    assert error.status == :error
    assert error.error == :boom
    assert error.message == "Action example_action failed: :boom"
    assert [%{name: "example_action", status: :error}] = error.actions

    invalid = Response.from_action_result(:oops, "example_action")
    assert invalid.status == :error
    assert invalid.error == {:invalid_action_result, :oops}
    assert invalid.message =~ "returned an invalid result"
  end

  test "builds unknown action and permission status responses" do
    response = Response.unknown_action("nope", "nope")

    assert response.status == :denied
    assert response.error == {:unknown_action, "nope"}
    assert [%{name: "nope", status: :denied}] = response.actions

    assert Response.permission_status(%{decision: :allowed}) == :completed
    assert Response.permission_status(%{decision: :needs_confirmation}) == :needs_confirmation
    assert Response.permission_status(%{decision: :denied}) == :denied
  end

  test "status predicates and diagnostics operate on response-like maps" do
    assert Response.completed?(%{status: "completed"})
    assert Response.needs_confirmation?(%{"status" => "needs_confirmation"})
    assert Response.denied?(%{status: :denied})

    assert %{diagnostics: [%{source: :test}]} =
             Response.append_diagnostic(%{message: "ok", status: :completed}, %{source: :test})
  end
end
