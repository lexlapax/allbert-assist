defmodule AllbertAssist.Conversations.UnifiedHistoryTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.UnifiedHistory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-unified-history-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    PluginRegistry.clear()
    PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
    PluginRegistry.register_module(AllbertAssist.Plugins.Email)
    PluginRegistry.register_module(AllbertAssist.Plugins.Discord)
    PluginRegistry.register_module(AllbertAssist.Plugins.Slack)

    on_exit(fn ->
      PluginRegistry.clear()
      PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)
      PluginRegistry.register_module(AllbertAssist.Plugins.Email)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
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

  test "redacts phone numbers in unified history content and channel refs" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Phone redaction")
    assert {:ok, message} = Conversations.append_user_message(thread, "text from +15551234567")

    phone_ref = %{
      channel: "signal",
      receiver_account_ref: "signal:+15557654321",
      provider_thread_ref: %{
        "thread_id" => "signal-phone",
        "aci" => "550e8400-e29b-41d4-a716-446655440000",
        "phone" => "+442071838750"
      },
      trust_class: :e2ee_origin
    }

    assert {:ok, _message_ref} =
             phone_ref
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: message.id,
               provider_message_id: "msg:+15551234567",
               direction: :in
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _thread_ref} =
             phone_ref
             |> Map.put(:canonical_thread_id, thread.id)
             |> ChannelThread.link_thread()

    assert {:ok, history} =
             UnifiedHistory.show_thread("alice", thread.id,
               viewer_channel: "cli",
               include_e2ee_origin: true,
               audit_context: %{actor: "alice", channel: "cli"}
             )

    assert [view] = history.messages
    assert view.content == "text from [REDACTED_PHONE]"
    assert [message_ref] = view.channel_refs
    assert message_ref.receiver_account_ref == "signal:[REDACTED_PHONE]"
    assert message_ref.provider_message_id == "msg:[REDACTED_PHONE]"

    assert [thread_ref] = history.thread_refs
    assert thread_ref.receiver_account_ref == "signal:[REDACTED_PHONE]"
    assert thread_ref.provider_thread_ref["phone"] == "[REDACTED_PHONE]"

    assert [channel] = history.channels
    assert channel.receiver_account_ref == "signal:[REDACTED_PHONE]"

    refute inspect(history) =~ "+15551234567"
    refute inspect(history) =~ "+15557654321"
    refute inspect(history) =~ "+442071838750"
  end

  test "default unified history excludes cross-channel e2ee-origin content" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "E2EE default")
    assert {:ok, signal_message} = Conversations.append_user_message(thread, "signal secret")
    assert {:ok, slack_message} = Conversations.append_assistant_message(thread, "public answer")

    assert {:ok, _signal_ref} =
             signal_ref("signal-thread-1")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: signal_message.id,
               provider_message_id: "signal-message-1",
               direction: :in,
               trust_class: :e2ee_origin
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _slack_ref} =
             slack_ref("1718040000.000150")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: slack_message.id,
               provider_message_id: "slack-message-1",
               direction: :out
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, history} = UnifiedHistory.show_thread("alice", thread.id, viewer_channel: "cli")

    assert Enum.map(history.messages, & &1.id) == [slack_message.id]
    assert Enum.map(history.channels, & &1.channel) == ["slack"]
    assert history.trust.filtered_e2ee_origin_count == 1
    refute inspect(history) =~ "signal secret"

    assert {:ok, signal_view} =
             UnifiedHistory.show_thread("alice", thread.id, viewer_channel: "signal")

    assert Enum.map(signal_view.messages, & &1.id) == [signal_message.id, slack_message.id]
    assert Enum.any?(signal_view.channels, &(&1.channel == "signal"))
  end

  test "e2ee-origin opt-in includes content and writes an audit" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "E2EE opt-in")
    assert {:ok, signal_message} = Conversations.append_user_message(thread, "operator approved")

    assert {:ok, _signal_ref} =
             signal_ref("signal-thread-2")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: signal_message.id,
               provider_message_id: "signal-message-2",
               direction: :in,
               trust_class: :e2ee_origin
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, history} =
             UnifiedHistory.show_thread("alice", thread.id,
               viewer_channel: "cli",
               include_e2ee_origin: true,
               audit_context: %{actor: "alice", channel: "cli"}
             )

    assert Enum.map(history.messages, & &1.id) == [signal_message.id]
    assert history.trust.opt_in_e2ee_origin_count == 1
    assert %{audit_path: audit_path} = history.trust.audit
    assert File.exists?(audit_path)
    audit = File.read!(audit_path)
    assert audit =~ "conversations.unified_history.e2ee_origin"
    assert audit =~ "new: included"
  end

  test "settings-level e2ee-origin opt-in is honored when request omits override" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "E2EE setting")
    assert {:ok, signal_message} = Conversations.append_user_message(thread, "settings approved")

    assert {:ok, _signal_ref} =
             signal_ref("signal-thread-setting")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: signal_message.id,
               provider_message_id: "signal-message-setting",
               direction: :in,
               trust_class: :e2ee_origin
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _resolved} =
             Settings.put("conversations.unified_history.include_e2ee_origin", true, %{
               audit?: false
             })

    assert {:ok, history} =
             UnifiedHistory.show_thread("alice", thread.id,
               viewer_channel: "cli",
               audit_context: %{actor: "alice", channel: "cli"}
             )

    assert Enum.map(history.messages, & &1.id) == [signal_message.id]
    assert history.trust.opt_in_e2ee_origin_count == 1
    assert %{audit_path: audit_path} = history.trust.audit
    assert File.exists?(audit_path)
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

  test "resume to server-readable channel requires confirmation when thread has e2ee-origin content" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Downgrade")
    assert {:ok, signal_message} = Conversations.append_user_message(thread, "signal-private")

    assert {:ok, _signal_ref} =
             signal_ref("signal-thread-3")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: signal_message.id,
               provider_message_id: "signal-message-3",
               direction: :in,
               trust_class: :e2ee_origin
             })
             |> ChannelThread.record_message_ref()

    assert {:ok, _link} =
             ChannelThread.link_identity(%{
               link_id: "alice-work",
               user_id: "alice",
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               external_user_id: "U0123"
             })

    params = %{
      thread_id: thread.id,
      user_id: "alice",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      external_user_id: "U0123",
      provider_thread_key: "1718040000.000300"
    }

    assert {:ok, pending} = Runner.run("resume_thread_on_channel", params, %{actor: "alice"})

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id =~ "conf_"

    assert get_in(pending.confirmation, ["params_summary", "target_trust_class"]) ==
             "server_readable"

    assert {:error, :not_found} =
             ChannelThread.lookup_thread(%{
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               provider_thread_key: "1718040000.000300",
               provider_thread_ref: %{"provider_thread_key" => "1718040000.000300"}
             })

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "approved"},
               %{
                 actor: "alice"
               }
             )

    assert approved.status == :completed
    assert approved.confirmation["operator_resolution"]["target_resumed?"]

    assert {:ok, thread.id} ==
             ChannelThread.lookup_thread(%{
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               provider_thread_key: "1718040000.000300",
               provider_thread_ref: %{"provider_thread_key" => "1718040000.000300"}
             })

    assert {:ok, resolved} = Confirmations.read(pending.confirmation_id)
    assert resolved["status"] == "approved"
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

  defp signal_ref(thread_id) do
    %{
      channel: "signal",
      receiver_account_ref: "signal:aci:alice",
      provider_thread_ref: %{
        "aci" => "alice",
        "thread_id" => thread_id
      }
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
