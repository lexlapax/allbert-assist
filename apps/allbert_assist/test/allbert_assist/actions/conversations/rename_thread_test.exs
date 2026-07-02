defmodule AllbertAssist.Actions.Conversations.RenameThreadTest do
  @moduledoc """
  v0.61b M4 — thread rename rides the one spine: registered action, existing
  `:conversation_write` permission, server-derived identity (context ahead of
  params), ownership-scoped fetch. A cross-user rename fails on the ownership
  scope, not on trust; the gate deny path leaves the thread untouched.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Conversations.RenameThread
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations
  alias AllbertAssist.Repo

  @moduletag :rename_thread

  defp create_thread(user_id, title \\ "Original title") do
    {:ok, thread} = Conversations.create_thread(%{user_id: user_id, title: title})
    thread
  end

  test "core rename_thread/3 renames the owner's thread and only the title" do
    thread = create_thread("local")

    assert {:ok, renamed} = Conversations.rename_thread("local", thread.id, "Weekly digest")
    assert renamed.id == thread.id
    assert renamed.title == "Weekly digest"
    assert renamed.kind == thread.kind
    assert renamed.user_id == "local"
  end

  test "core rename_thread/3 is ownership-scoped" do
    thread = create_thread("alice", "Alice's thread")

    assert {:error, {:thread_not_found, _}} =
             Conversations.rename_thread("local", thread.id, "Hijacked")

    assert Repo.reload!(thread).title == "Alice's thread"
  end

  test "owner renames through the Runner boundary; params user_id cannot rescope" do
    thread = create_thread("local")

    # params claim "alice"; the server-derived context identity "local" wins.
    assert {:ok, %{status: :completed, thread: %{title: "Renamed via action"}}} =
             Runner.run(
               "rename_thread",
               %{thread_id: thread.id, title: "Renamed via action", user_id: "alice"},
               %{user_id: "local"}
             )

    assert Repo.reload!(thread).title == "Renamed via action"
  end

  test "cross-user rename is denied by ownership scope, not trust" do
    alice_thread = create_thread("alice", "Alice's thread")

    assert {:ok, %{status: :error, error: {:thread_not_found, _}}} =
             Runner.run(
               "rename_thread",
               %{thread_id: alice_thread.id, title: "Hijacked", user_id: "alice"},
               %{user_id: "local"}
             )

    assert Repo.reload!(alice_thread).title == "Alice's thread"
  end

  test "title validation holds through the action (1..160, non-blank)" do
    thread = create_thread("local")

    assert {:ok, %{status: :error, error: :missing_title}} =
             Runner.run(
               "rename_thread",
               %{thread_id: thread.id, title: "   "},
               %{user_id: "local"}
             )

    too_long = String.duplicate("a", 161)

    assert {:ok, %{status: :error, error: %Ecto.Changeset{}}} =
             Runner.run(
               "rename_thread",
               %{thread_id: thread.id, title: too_long},
               %{user_id: "local"}
             )

    assert Repo.reload!(thread).title == "Original title"
  end

  test "the gate deny path returns denied and leaves the thread untouched" do
    thread = create_thread("local")

    # An unregistered action boundary is a real PermissionGate context denial:
    # Security.Context resolves `selected_action` against the live registry, so
    # a probe name that is not registered denies any permission class.
    denied_context = %{
      user_id: "local",
      selected_action: "unregistered_boundary_probe"
    }

    assert {:ok, %{status: status, actions: [%{status: :denied}]}} =
             RenameThread.run(%{thread_id: thread.id, title: "Denied"}, denied_context)

    assert status in [:denied, :error]
    assert Repo.reload!(thread).title == "Original title"

    IO.puts(
      "thread-rename-ownership-001 status=pass identity=server_derived scope=ownership " <>
        "gate_deny=exercised authority=conversation_write_existing"
    )
  end
end
