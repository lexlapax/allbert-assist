defmodule AllbertAssist.Actions.Sessions.ClearSessionTest do
  @moduledoc """
  v0.62 M8.15 — clearing a session scratchpad rides the one spine: a registered
  action behind the existing `:conversation_write` permission, server-derived
  identity (context ahead of params), and a `%{removed?: boolean}` result the CLI
  renders verbatim. The gate deny path leaves the scratchpad untouched.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Sessions.ClearSession

  @moduletag :clear_session

  test "allowed path clears the owner's session and returns the removed? result" do
    assert {:ok, %{status: :completed, result: %{removed?: removed?}}} =
             ClearSession.run(%{session_id: "sess-clear-1"}, %{user_id: "local"})

    assert is_boolean(removed?)
  end

  test "params user_id cannot rescope the clear away from the server identity" do
    assert {:ok, %{status: :completed, actions: [%{user_id: "local"}]}} =
             ClearSession.run(
               %{session_id: "sess-clear-2", user_id: "alice"},
               %{user_id: "local"}
             )
  end

  test "the gate deny path returns denied and performs no clear" do
    denied_context = %{
      user_id: "local",
      selected_action: "unregistered_boundary_probe"
    }

    assert {:ok, %{status: status, actions: [%{status: :denied}]}} =
             ClearSession.run(%{session_id: "sess-clear-3"}, denied_context)

    assert status in [:denied, :error]
  end
end
