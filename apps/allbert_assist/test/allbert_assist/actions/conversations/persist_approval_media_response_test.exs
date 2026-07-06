defmodule AllbertAssist.Actions.Conversations.PersistApprovalMediaResponseTest do
  @moduledoc """
  v0.62 M0.1 — the approval-media assistant-message write rides the one spine:
  registered action on the existing `:conversation_write` permission,
  server-derived identity (context ahead of params), ownership-scoped fetch.
  Cross-user writes fail on ownership scope; the gate deny path writes nothing.
  """
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Conversations.PersistApprovalMediaResponse
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations

  @moduletag :approval_media_write

  defp create_thread(user_id) do
    {:ok, thread} = Conversations.create_thread(%{user_id: user_id, title: "Media thread"})
    thread
  end

  defp messages(thread) do
    Conversations.list_messages(thread)
  end

  test "appends one assistant message with action_log/metadata on the owner's thread" do
    thread = create_thread("local")

    assert {:ok, %{status: :completed, actions: [%{status: :completed}]}} =
             Runner.run(
               "persist_approval_media_response",
               %{
                 thread_id: thread.id,
                 message: "Generated media output.",
                 action_log: %{status: :completed},
                 metadata: %{channel: :live_view, media_outputs: [%{kind: "image"}]}
               },
               %{user_id: "local"}
             )

    assert [message] = messages(thread)
    assert message.role == "assistant"
    assert message.content == "Generated media output."
  end

  test "params user_id cannot rescope the write; context identity wins" do
    thread = create_thread("local")

    assert {:ok, %{status: :completed}} =
             Runner.run(
               "persist_approval_media_response",
               %{thread_id: thread.id, message: "Recorded.", user_id: "alice"},
               %{user_id: "local"}
             )

    assert [_message] = messages(thread)
  end

  test "cross-user write is denied by ownership scope, not trust" do
    alice_thread = create_thread("alice")

    assert {:ok, %{status: :error, error: {:thread_not_found, _}}} =
             Runner.run(
               "persist_approval_media_response",
               %{thread_id: alice_thread.id, message: "Hijacked."},
               %{user_id: "local"}
             )

    assert messages(alice_thread) == []
  end

  test "a blank message is rejected before any write" do
    thread = create_thread("local")

    assert {:ok, %{status: :error, error: :missing_message}} =
             Runner.run(
               "persist_approval_media_response",
               %{thread_id: thread.id, message: "   "},
               %{user_id: "local"}
             )

    assert messages(thread) == []
  end

  test "the gate deny path returns denied and writes nothing" do
    thread = create_thread("local")

    denied_context = %{
      user_id: "local",
      selected_action: "unregistered_boundary_probe"
    }

    assert {:ok, %{status: status, actions: [%{status: :denied}]}} =
             PersistApprovalMediaResponse.run(
               %{thread_id: thread.id, message: "Denied."},
               denied_context
             )

    assert status in [:denied, :error]
    assert messages(thread) == []

    IO.puts(
      "m0.1-approval-media-spine status=pass identity=server_derived scope=ownership " <>
        "gate_deny=exercised authority=conversation_write_existing"
    )
  end
end
