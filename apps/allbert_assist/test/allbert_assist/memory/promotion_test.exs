defmodule AllbertAssist.Memory.PromotionTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Memory.PromoteConversationTurn
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Promotion
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Memory, as: MemoryTask

  setup do
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_confirmations = Application.get_env(:allbert_assist, Confirmations)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-memory-promotion-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(home, "confirmations"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
      restore_env(Confirmations, original_confirmations)
      Mix.Task.reenable("allbert.memory")
      File.rm_rf!(home)
    end)

    :ok
  end

  test "from_thread_message builds bounded memory attrs for an owned message" do
    {:ok, thread} = Conversations.create_general_thread("alice", "Promotion source")
    {:ok, message} = Conversations.append_user_message(thread, String.duplicate("abc ", 700))

    assert {:ok, attrs} =
             Promotion.from_thread_message("alice", thread.id, message.id, %{
               category: "notes",
               summary: "Selected turn"
             })

    assert attrs.actor == "alice"
    assert attrs.category == :notes
    assert attrs.summary == "Selected turn"
    assert byte_size(attrs.body) <= 2_000
  end

  test "promote_conversation_turn requires confirmation and approval writes memory" do
    {:ok, thread} = Conversations.create_general_thread("alice", "Promotion source")
    {:ok, message} = Conversations.append_user_message(thread, "Alice likes crisp summaries.")

    assert {:ok, pending} =
             PromoteConversationTurn.run(
               %{
                 user_id: "alice",
                 thread_id: thread.id,
                 message_id: message.id,
                 category: "preferences",
                 summary: "Crisp summaries"
               },
               %{user_id: "alice", actor: "alice", channel: :test}
             )

    assert pending.status == :needs_confirmation
    assert {:ok, []} = Memory.list_entries(user_id: "alice")

    assert {:ok, approved} =
             ApproveConfirmation.run(%{id: pending.confirmation_id, reason: "test"}, %{
               user_id: "alice",
               actor: "alice",
               channel: :test
             })

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert {:ok, [entry]} = Memory.list_entries(user_id: "alice", category: :preferences)
    assert entry.body =~ "crisp summaries"
  end

  test "promote_conversation_turn rejects another user's message before confirmation" do
    {:ok, thread} = Conversations.create_general_thread("alice", "Promotion source")
    {:ok, message} = Conversations.append_user_message(thread, "Private")

    assert {:ok, response} =
             PromoteConversationTurn.run(
               %{user_id: "bob", thread_id: thread.id, message_id: message.id},
               %{user_id: "bob", actor: "bob", channel: :test}
             )

    assert response.status == :error
    assert response.error == {:thread_not_found, thread.id}
    assert [] = Confirmations.list()
  end

  test "mix allbert.memory promote-turn displays a confirmation id" do
    {:ok, thread} = Conversations.create_general_thread("alice", "CLI promotion")
    {:ok, message} = Conversations.append_user_message(thread, "Alice likes CLI smoke tests.")

    output =
      capture_io(fn ->
        assert :ok =
                 MemoryTask.run([
                   "promote-turn",
                   "--thread-id",
                   thread.id,
                   "--message-id",
                   message.id,
                   "--category",
                   "notes",
                   "--user",
                   "alice"
                 ])
      end)

    assert output =~ "Confirmation:"
    assert output =~ "No memory was written."
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
