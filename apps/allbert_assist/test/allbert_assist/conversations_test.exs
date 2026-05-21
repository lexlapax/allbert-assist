defmodule AllbertAssist.ConversationsTest do
  use AllbertAssist.DataCase, async: true

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.Conversations.Thread
  alias AllbertAssist.Repo

  describe "threads" do
    test "creates threads with opaque ids and required ownership fields" do
      assert {:ok, %Thread{} = thread} =
               Conversations.create_thread(%{user_id: "alice", title: "First topic"})

      assert String.starts_with?(thread.id, "thr_")
      assert thread.user_id == "alice"
      assert thread.kind == "general"
      assert thread.app_id == nil
      assert %DateTime{} = thread.last_message_at
    end

    test "rejects blank required thread fields" do
      assert {:error, changeset} = Conversations.create_thread(%{user_id: "", title: ""})

      assert %{user_id: [_], title: [_]} = errors_on(changeset)
    end

    test "resolves omitted thread to the most recently updated general user thread" do
      assert {:ok, old_thread} =
               Conversations.create_thread(%{
                 user_id: "alice",
                 title: "Old",
                 last_message_at: ~U[2026-05-13 10:00:00Z]
               })

      assert {:ok, new_thread} =
               Conversations.create_thread(%{
                 user_id: "alice",
                 title: "New",
                 last_message_at: ~U[2026-05-13 11:00:00Z]
               })

      assert {:ok, bob_thread} =
               Conversations.create_thread(%{
                 user_id: "bob",
                 title: "Bob",
                 last_message_at: ~U[2026-05-13 12:00:00Z]
               })

      assert {:ok, resolved} = Conversations.resolve_thread(%{user_id: "alice"})
      assert resolved.id == new_thread.id
      refute resolved.id == old_thread.id
      refute resolved.id == bob_thread.id
    end

    test "resolves omitted thread by creating one when none exists" do
      assert {:ok, thread} =
               Conversations.resolve_thread(%{user_id: "alice", text: "  Hello   from Alice  "})

      assert String.starts_with?(thread.id, "thr_")
      assert thread.user_id == "alice"
      assert thread.title == "Hello from Alice"
    end

    test "new_thread always creates a new general thread" do
      assert {:ok, first} = Conversations.resolve_thread(%{user_id: "alice", text: "First"})
      assert {:ok, second} = Conversations.resolve_thread(%{user_id: "alice", new_thread: true})

      assert first.id != second.id
      assert second.title == "New conversation"
    end

    test "explicit thread lookup is scoped by user" do
      assert {:ok, thread} = Conversations.create_general_thread("alice", "Secret topic")
      thread_id = thread.id

      assert {:ok, scoped} =
               Conversations.resolve_thread(%{user_id: "alice", thread_id: thread_id})

      assert scoped.id == thread_id

      assert {:error, {:thread_not_found, ^thread_id}} =
               Conversations.resolve_thread(%{user_id: "bob", thread_id: thread_id})
    end

    test "rejects conflicting explicit and new thread request" do
      assert {:error, :thread_conflict} =
               Conversations.resolve_thread(%{
                 user_id: "alice",
                 thread_id: "thr_existing",
                 new_thread: true
               })
    end
  end

  describe "messages" do
    setup do
      {:ok, thread} = Conversations.create_general_thread("alice", "Message topic")
      {:ok, thread: thread}
    end

    test "appends user and assistant messages in order", %{thread: thread} do
      assert {:ok, user_message} =
               Conversations.append_user_message(thread, "hello",
                 input_signal_id: "sig-in",
                 metadata: %{client: "cli"}
               )

      assert {:ok, assistant_message} =
               thread
               |> Repo.reload!()
               |> Conversations.append_assistant_message("Hello.",
                 action_log: %{status: "completed"},
                 trace_id: "trace.md",
                 response_signal_id: "sig-out"
               )

      assert String.starts_with?(user_message.id, "msg_")
      assert user_message.role == "user"
      assert user_message.input_signal_id == "sig-in"
      assert user_message.metadata == %{"client" => "cli"}

      assert String.starts_with?(assistant_message.id, "msg_")
      assert assistant_message.role == "assistant"
      assert assistant_message.action_log == %{"status" => "completed"}
      assert assistant_message.trace_id == "trace.md"

      messages = Conversations.list_messages(thread)
      assert Enum.map(messages, & &1.id) == [user_message.id, assistant_message.id]

      reloaded = Repo.reload!(thread)
      assert DateTime.compare(reloaded.last_message_at, thread.last_message_at) in [:gt, :eq]
    end

    test "rejects invalid message roles", %{thread: thread} do
      assert {:error, changeset} =
               Conversations.append_message(thread, %{role: "system", content: "hidden"})

      assert %{role: [_]} = errors_on(changeset)
    end

    test "returns bounded recent context in chronological order", %{thread: thread} do
      inserted =
        for index <- 1..14 do
          {:ok, message} =
            Conversations.append_user_message(Repo.reload!(thread), "message #{index}")

          message
        end

      current = List.last(inserted)

      context =
        thread
        |> Repo.reload!()
        |> Conversations.recent_context(limit: 12, exclude_message_id: current.id)

      assert length(context) == 12
      assert List.first(context).content == "message 2"
      assert List.last(context).content == "message 13"
      refute Enum.any?(context, &(&1.content == "message 14"))
    end

    test "normalizes action logs and metadata before map persistence", %{thread: thread} do
      assert {:ok, assistant_message} =
               Conversations.append_assistant_message(thread, "Denied.",
                 action_log: %{
                   status: :denied,
                   request: %{
                     denial_reason: {:host_not_allowlisted, "wikipedia.com"},
                     query?: false,
                     checked_at: ~U[2026-05-21 09:30:00Z]
                   }
                 },
                 metadata: %{active_app: :allbert}
               )

      assert Jason.encode!(assistant_message.action_log)
      assert Jason.encode!(assistant_message.metadata)

      assert assistant_message.action_log["status"] == "denied"

      assert assistant_message.action_log["request"]["denial_reason"] ==
               "{:host_not_allowlisted, \"wikipedia.com\"}"

      assert assistant_message.action_log["request"]["query?"] == false
      assert assistant_message.action_log["request"]["checked_at"] == "2026-05-21T09:30:00Z"
      assert assistant_message.metadata["active_app"] == "allbert"
    end
  end

  describe "list/show" do
    test "lists and shows only user-owned threads" do
      assert {:ok, alice} = Conversations.create_general_thread("alice", "Alice thread")
      assert {:ok, bob} = Conversations.create_general_thread("bob", "Bob thread")

      assert {:ok, _message} = Conversations.append_user_message(alice, "hello")
      assert {:ok, _message} = Conversations.append_user_message(bob, "secret")

      assert [%Thread{id: alice_id}] = Conversations.list_threads("alice")
      assert alice_id == alice.id

      assert {:ok, %{thread: shown, messages: [%Message{content: "hello"}]}} =
               Conversations.show_thread("alice", alice.id)

      assert shown.id == alice.id

      assert {:error, {:thread_not_found, _}} = Conversations.show_thread("alice", bob.id)
    end
  end
end
