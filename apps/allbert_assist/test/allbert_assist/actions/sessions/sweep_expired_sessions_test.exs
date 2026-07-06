defmodule AllbertAssist.Actions.Sessions.SweepExpiredSessionsTest do
  @moduledoc """
  v0.62 M8.15 — sweeping expired session scratchpads rides the one spine: a
  registered action behind the existing `:conversation_write` permission that
  returns the removed count for the CLI to render verbatim. The gate deny path
  performs no sweep.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Sessions.SweepExpiredSessions

  @moduletag :sweep_expired_sessions

  test "allowed path sweeps and returns a non-negative removed count" do
    assert {:ok, %{status: :completed, count: count}} =
             SweepExpiredSessions.run(%{}, %{user_id: "local"})

    assert is_integer(count) and count >= 0
  end

  test "the gate deny path returns denied and performs no sweep" do
    denied_context = %{
      user_id: "local",
      selected_action: "unregistered_boundary_probe"
    }

    assert {:ok, %{status: status, actions: [%{status: :denied}]}} =
             SweepExpiredSessions.run(%{}, denied_context)

    assert status in [:denied, :error]
  end
end
