defmodule AllbertAssist.Runtime.ResponseTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

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

  test "normalizes action callback errors and invalid results" do
    error = Response.from_action_result({:error, :boom}, "example_action")
    assert error.status == :error
    assert error.error == :boom
    assert error.message == "Action example_action failed: :boom"
    assert [%{name: "example_action", status: :error, error: :action_failed}] = error.actions

    invalid = Response.from_action_result(:oops, "example_action")
    assert invalid.status == :error
    assert invalid.error == :invalid_action_result
    assert invalid.message =~ "returned an invalid result"
  end

  test "redacts callback errors before rendering operator-visible text" do
    secret = "sk-secret123456"

    response =
      Response.from_action_result(
        {:error, %{api_key: secret, detail: "provider rejected #{secret}"}},
        "example_action"
      )

    serialized = inspect(response)
    refute serialized =~ secret
    assert response.message =~ "[REDACTED]"
    assert response.error == %{api_key: "[REDACTED]", detail: "provider rejected [REDACTED]"}
    assert response.actions == [%{name: "example_action", status: :error, error: :action_failed}]

    invalid = Response.from_action_result(%{raw_response: secret}, "example_action")
    refute inspect(invalid) =~ secret

    invalid_canonical =
      Response.canonical_action_result(
        {:ok, %{message: "done", status: :unknown, raw_response: secret}},
        "example_action"
      )

    refute inspect(invalid_canonical) =~ secret

    accepted_without_message =
      Response.canonical_action_result(
        {:ok, %{status: :completed, raw_response: secret}},
        "example_action"
      )

    assert accepted_without_message.message == "Action example_action completed."
    refute accepted_without_message.message =~ secret
  end

  test "defines and validates the canonical internal action response" do
    response =
      Response.canonical_action_result({:ok, %{message: "done", status: "completed"}}, "demo")

    assert Response.canonical_action_response?(response)
    assert {:ok, ^response} = Response.validate_action_response(response)
    assert response.status == :completed
    assert response.model_payload == "done"
    assert response.surface_payload == "done"

    refute Response.canonical_action_response?(%{message: "missing fields"})

    assert {:error, {:invalid_canonical_action_response, %{message: "missing fields"}}} =
             Response.validate_action_response(%{message: "missing fields"})

    assert Response.action_response_schema().status == :atom
  end

  test "canonical action admission rejects present malformed fields instead of defaulting them" do
    for malformed <- [
          %{message: "done", status: "unknown_status"},
          %{message: "done", status: :unknown_status},
          %{message: "done", status: :completed, actions: :not_a_list},
          %{message: "done", status: :completed, diagnostics: :not_a_list},
          %{message: "done", status: :completed, decision: :not_a_map},
          %{message: "done", status: :completed, resource_access: :not_a_list},
          %{message: "done", status: :completed, approval_handoff: :not_a_map}
        ] do
      response = Response.canonical_action_result({:ok, malformed}, "demo")

      assert response.status == :error
      assert response.error == :invalid_canonical_action_response
      assert response.message == "Action demo returned an invalid canonical response."

      assert response.actions == [
               %{name: "demo", status: :error, error: :invalid_canonical_action_response}
             ]
    end
  end

  test "canonical action admission preserves the inventoried specialized statuses" do
    specialized = [
      :answer,
      :already_finished,
      :clarification,
      :degraded,
      :disabled,
      :finalizing,
      :needs_clarification,
      :objective_abandoned,
      :objective_cancelled,
      :objective_failed,
      :queued,
      :running,
      :still_blocked,
      :stopped
    ]

    assert Enum.all?(specialized, &(&1 in Response.action_statuses()))

    for status <- specialized do
      atom_response =
        Response.canonical_action_result({:ok, %{message: "state", status: status}}, "demo")

      string_response =
        Response.canonical_action_result(
          {:ok, %{message: "state", status: Atom.to_string(status)}},
          "demo"
        )

      assert atom_response.status == status
      assert string_response.status == status
      assert Response.canonical_action_response?(atom_response)
      assert Response.canonical_action_response?(string_response)
    end
  end

  test "every admitted status has an explicit public-protocol outcome class" do
    outcomes = Response.action_status_outcomes()

    assert MapSet.new(Map.keys(outcomes)) == MapSet.new(Response.action_statuses())

    assert Enum.all?(outcomes, fn {_status, class} ->
             class in [:success, :needs_confirmation, :denied, :error]
           end)

    assert outcomes.completed == :success
    assert outcomes.needs_confirmation == :needs_confirmation
    assert outcomes.denied == :denied
    assert outcomes.rejected == :denied

    for status <- [:error, :failed, :unsupported, :unavailable] do
      assert outcomes[status] == :error
    end

    for status <-
          Response.action_statuses() --
            [:needs_confirmation, :denied, :rejected, :error, :failed, :unsupported, :unavailable] do
      assert outcomes[status] == :success
    end

    assert Response.outcome_class(%{status: :not_in_inventory}) == :error
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
