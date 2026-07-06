defmodule AllbertAssist.Actions.Conversations.CompleteThreadTest do
  @moduledoc """
  v0.62 M8.15 — thread completion rides the one spine: a registered action,
  existing `:conversation_write` permission, server-derived identity (context
  ahead of params), ownership-scoped completion. A cross-user completion fails on
  the ownership scope; the gate deny path leaves the thread untouched.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Conversations.CompleteThread
  alias AllbertAssist.Conversations
  alias AllbertAssist.Repo

  @moduletag :complete_thread

  defp create_thread(user_id, title \\ "Original title") do
    {:ok, thread} = Conversations.create_thread(%{user_id: user_id, title: title})
    thread
  end

  test "allowed path completes the owner's thread and returns it" do
    thread = create_thread("local")

    assert {:ok, %{status: :completed, thread: completed}} =
             CompleteThread.run(%{thread_id: thread.id}, %{user_id: "local"})

    assert completed.id == thread.id
    refute is_nil(completed.completed_at)
  end

  test "params user_id cannot rescope the completion away from the server identity" do
    thread = create_thread("local")

    # params claim "alice"; the server-derived context identity "local" wins.
    assert {:ok, %{status: :completed, thread: completed}} =
             CompleteThread.run(
               %{thread_id: thread.id, user_id: "alice"},
               %{user_id: "local"}
             )

    assert completed.id == thread.id
  end

  test "cross-user completion is denied by ownership scope, not trust" do
    alice_thread = create_thread("alice", "Alice's thread")

    assert {:ok, %{status: :error, error: {:thread_not_found, _}}} =
             CompleteThread.run(
               %{thread_id: alice_thread.id, user_id: "alice"},
               %{user_id: "local"}
             )

    assert is_nil(Repo.reload!(alice_thread).completed_at)
  end

  test "the gate deny path returns denied and leaves the thread untouched" do
    thread = create_thread("local")

    denied_context = %{
      user_id: "local",
      selected_action: "unregistered_boundary_probe"
    }

    assert {:ok, %{status: status, actions: [%{status: :denied}]}} =
             CompleteThread.run(%{thread_id: thread.id}, denied_context)

    assert status in [:denied, :error]
    assert is_nil(Repo.reload!(thread).completed_at)
  end
end
