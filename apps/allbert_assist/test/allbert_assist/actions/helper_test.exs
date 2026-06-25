defmodule AllbertAssist.Actions.HelperTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.ErrorExtraction
  alias AllbertAssist.Actions.Helper

  test "extracts direct and nested action errors" do
    assert ErrorExtraction.from_response(%{error: :direct, message: "ignored"}) == :direct

    assert ErrorExtraction.from_response(%{
             message: "fallback",
             actions: [%{confirmation_metadata: %{error: :blocked}}]
           }) == :blocked

    assert ErrorExtraction.from_response(%{message: "fallback", actions: []}) == "fallback"
  end

  test "completed_action returns ok only for completed responses" do
    assert {:ok, %{status: :completed}} =
             Helper.completed_action("registry_health", %{}, %{actor: "test"})

    assert {:error, reason} =
             Helper.completed_action("missing_helper_fixture", %{}, %{actor: "test"})

    assert inspect(reason) =~ "unknown_action"
  end

  test "completed_action can return the full response for legacy printers" do
    assert {:error, %{status: :denied} = response} =
             Helper.completed_action(
               "missing_helper_fixture",
               %{},
               %{actor: "test"},
               error: :response
             )

    assert inspect(response.error) =~ "unknown_action"
  end
end
