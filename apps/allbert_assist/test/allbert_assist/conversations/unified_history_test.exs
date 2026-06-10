defmodule AllbertAssist.Conversations.UnifiedHistoryTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

  setup do
    PluginRegistry.clear()
    PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    PluginRegistry.register_module(AllbertAssist.Plugins.Discord)
    PluginRegistry.register_module(AllbertAssist.Plugins.Slack)

    on_exit(fn ->
      PluginRegistry.clear()
      PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
      PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    end)

    :ok
  end

  test "shows redacted canonical messages across channel refs in Allbert ingest order" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Cross channel")
    assert {:ok, first} = Conversations.append_user_message(thread, "hello from slack")
    assert {:ok, second} = Conversations.append_assistant_message(thread, "token sk-secret123")

    assert {:ok, _ref} =
             slack_ref("1718040000.000100")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: first.id,
               provider_message_id: "slack-user-1",
               direction: :in
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _ref} =
             telegram_ref("42")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: second.id,
               provider_message_id: "telegram-bot-1",
               direction: :out
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _thread_ref} =
             telegram_ref("42")
             |> Map.put(:canonical_thread_id, thread.id)
             |> ChannelThread.link_thread()

    assert {:ok, history} = UnifiedHistory.show_thread("alice", thread.id)

    assert Enum.map(history.messages, & &1.id) == [first.id, second.id]
    assert Enum.map(history.channels, & &1.channel) == ["slack", "telegram"]
    assert history.ordering == :allbert_ingest_sequence
    assert history.redaction == :runtime_redactor
    assert history.messages |> List.last() |> Map.fetch!(:content) == "token [REDACTED]"
    refute inspect(history) =~ "sk-secret123"
  end

  test "resume action links only the same local user and an explicit external identity" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Resume me")

    assert {:ok, _link} =
             ChannelThread.link_identity(%{
               link_id: "alice-work",
               user_id: "alice",
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               external_user_id: "U0123"
             })

    assert {:ok, %{status: :completed, resume: resume}} =
             Runner.run("resume_thread_on_channel", %{
               thread_id: thread.id,
               user_id: "alice",
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               external_user_id: "U0123",
               provider_thread_key: "1718040000.000100"
             })

    assert resume.thread_id == thread.id
    assert resume.user_id == "alice"
    assert resume.continuity.mode == :native_thread

    assert {:ok, thread.id} ==
             ChannelThread.lookup_thread(%{
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               provider_thread_key: "1718040000.000100",
               provider_thread_ref: %{"provider_thread_key" => "1718040000.000100"}
             })

    assert {:ok, %{status: :denied, error: {:thread_not_found, _thread_id}}} =
             Runner.run("resume_thread_on_channel", %{
               thread_id: thread.id,
               user_id: "bob",
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               external_user_id: "U0123",
               provider_thread_key: "1718040000.000100"
             })
  end

  test "external resume requires identity link while local surfaces do not" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Local resume")

    assert {:error, :missing_identity_link} =
             UnifiedHistory.resume_thread_on_channel(%{
               thread_id: thread.id,
               user_id: "alice",
               channel: "telegram",
               receiver_account_ref: "telegram:bot:bot1:chat:42",
               external_user_id: "42",
               provider_thread_key: "topic-1"
             })

    assert {:ok, resume} =
             UnifiedHistory.resume_thread_on_channel(%{
               thread_id: thread.id,
               user_id: "alice",
               channel: "cli",
               request_id: "req_1"
             })

    assert resume.channel == "cli"
    assert resume.continuity.mode == :rich_surface
  end

  test "continuity reports native, reply-chain, and flat degradation modes" do
    assert UnifiedHistory.continuity(%{strategy: :native_thread, threading: :native_threads}) ==
             %{
               mode: :native_thread,
               threading: :native_threads,
               degradation: :none
             }

    assert UnifiedHistory.continuity(%{strategy: :reply_chain, threading: :reply_chain}) == %{
             mode: :reply_chain,
             threading: :reply_chain,
             degradation: :reply_chain
           }

    assert UnifiedHistory.continuity(%{strategy: :flat_stream, threading: :flat}) == %{
             mode: :flat_stream,
             threading: :flat,
             degradation: :flat
           }
  end

  defp slack_ref(thread_ts) do
    %{
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        "team_id" => "T0123",
        "channel_id" => "C0123",
        "thread_ts" => thread_ts
      }
    }
  end

  defp telegram_ref(message_thread_id) do
    %{
      channel: "telegram",
      receiver_account_ref: "telegram:bot:bot1:chat:42",
      provider_thread_ref: %{
        "chat_id" => "42",
        "message_thread_id" => message_thread_id
      }
    }
  end
end
