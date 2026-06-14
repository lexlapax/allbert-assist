defmodule AllbertAssist.Conversations.ChannelThreadTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ConversationMessageRef
  alias AllbertAssist.Conversations.CrossChannelIdentityLink
  alias AllbertAssist.Runtime
  alias AllbertAssist.Settings
  alias AllbertAssist.Trace

  setup do
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-channel-thread-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    on_exit(fn ->
      restore_app_env(Runtime, original_runtime_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Trace, original_trace_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "links provider thread refs with owner and receiver account scoped uniqueness" do
    assert {:ok, alice} = Conversations.create_general_thread("alice", "Slack root")
    assert {:ok, other_receiver} = Conversations.create_general_thread("alice", "Other receiver")
    ref = slack_ref("1718040000.000100")

    assert {:ok, linked} =
             ref
             |> Map.put(:canonical_thread_id, alice.id)
             |> ChannelThread.link_thread()

    assert linked.owner_scope == "local"
    assert linked.channel == "slack"
    assert linked.receiver_account_ref == "slack:T0123"
    assert linked.trust_class == "server_readable"

    assert linked.provider_thread_key ==
             ChannelThread.provider_thread_key(ref.provider_thread_ref)

    assert {:ok, alice.id} == ChannelThread.lookup_thread(ref)

    assert {:ok, other_linked} =
             ref
             |> Map.put(:receiver_account_ref, "slack:T9999")
             |> Map.put(:canonical_thread_id, other_receiver.id)
             |> ChannelThread.link_thread()

    assert other_linked.canonical_thread_id == other_receiver.id

    alice_thread_id = alice.id

    assert {:error, {:thread_ref_conflict, ^alice_thread_id}} =
             ref
             |> Map.put(:canonical_thread_id, other_receiver.id)
             |> ChannelThread.link_thread()
  end

  test "records split provider message refs and detects outbound echo" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Message refs")
    assert {:ok, assistant} = Conversations.append_assistant_message(thread, "First part")
    assert {:ok, user_message} = Conversations.append_user_message(thread, "Inbound")

    base =
      slack_ref("1718040000.000200")
      |> Map.merge(%{
        canonical_thread_id: thread.id,
        canonical_message_id: assistant.id,
        provider_message_id: "bot-1718040000.000201",
        direction: :out
      })

    assert {:ok, part_0} = ChannelThread.record_message_ref(Map.put(base, :part_id, "0"))
    assert {:ok, part_1} = ChannelThread.record_message_ref(Map.put(base, :part_id, "1"))
    assert part_0.id != part_1.id

    assert Repo.aggregate(ConversationMessageRef, :count, :id) == 2

    assert {:ok, same_part_0} = ChannelThread.record_message_ref(Map.put(base, :part_id, "0"))
    assert same_part_0.id == part_0.id

    assert ChannelThread.echo?(%{
             channel: "slack",
             receiver_account_ref: "slack:T0123",
             provider_message_id: "bot-1718040000.000201",
             part_id: "0"
           })

    assert ChannelThread.echo?(%{
             channel: "slack",
             receiver_account_ref: "slack:T0123",
             provider_message_id: "bot-1718040000.000201"
           })

    assert {:ok, thread.id} ==
             ChannelThread.lookup_message_thread(%{
               channel: "slack",
               receiver_account_ref: "slack:T0123",
               provider_message_id: "bot-1718040000.000201"
             })

    refute ChannelThread.echo?(%{
             channel: "slack",
             receiver_account_ref: "slack:T0123",
             provider_message_id: "user-1718040000.000202"
           })

    assert {:ok, inbound_ref} =
             slack_ref("1718040000.000200")
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: user_message.id,
               provider_message_id: "user-1718040000.000202",
               direction: :in
             })
             |> ChannelThread.record_message_ref()

    assert inbound_ref.direction == "in"
    assert inbound_ref.trust_class == "server_readable"
  end

  test "stamps explicit trust class on thread and message refs" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Signal refs")
    assert {:ok, message} = Conversations.append_user_message(thread, "signal hello")

    ref =
      %{
        channel: "signal",
        receiver_account_ref: "signal:+15551234567",
        provider_thread_ref: %{"aci" => "aci-1"},
        trust_class: :e2ee_origin
      }

    assert {:ok, thread_ref} =
             ref
             |> Map.put(:canonical_thread_id, thread.id)
             |> ChannelThread.link_thread()

    assert thread_ref.trust_class == "e2ee_origin"

    assert {:ok, message_ref} =
             ref
             |> Map.merge(%{
               canonical_thread_id: thread.id,
               canonical_message_id: message.id,
               provider_message_id: "signal-message-1",
               direction: :in
             })
             |> ChannelThread.record_message_ref()

    assert message_ref.trust_class == "e2ee_origin"
  end

  test "resolves reply targets from descriptor threading capability" do
    assert {:ok, native} =
             ChannelThread.resolve_reply_target(slack_ref("1718040000.000300"), %{
               threading: :native_threads
             })

    assert native.strategy == :native_thread
    assert native.threading == :native_threads

    assert {:ok, flat} =
             ChannelThread.resolve_reply_target(slack_ref("1718040000.000300"), %{
               "threading" => "flat"
             })

    assert flat.strategy == :flat_stream
  end

  test "resolves timestamp reply keys for Signal-style quote targets" do
    aci = "550e8400-e29b-41d4-a716-446655440000"

    assert {:ok, target} =
             ChannelThread.resolve_reply_target(
               %{
                 channel: "signal",
                 receiver_account_ref: "signal:primary",
                 provider_thread_ref: %{
                   "author_aci" => aci,
                   "message_timestamp_ms" => 1_718_040_000_000
                 },
                 trust_class: :e2ee_origin
               },
               %{threading: :reply_chain, reply_key_type: :timestamp}
             )

    assert target.strategy == :reply_chain
    assert target.threading == :reply_chain
    assert target.reply_key_type == :timestamp

    assert target.reply_key == %{
             type: :timestamp,
             timestamp_ms: 1_718_040_000_000,
             author_ref: aci
           }

    assert target.trust_class == :e2ee_origin
    assert target.degradation == :none
  end

  test "degrades expired quote windows to flat stream without changing the provider key" do
    quoted_at = ~U[2026-01-01 00:00:00Z]
    checked_at = ~U[2026-01-03 00:00:01Z]

    ref = %{
      channel: "whatsapp",
      receiver_account_ref: "whatsapp:waba:123:phone:[REDACTED_PHONE]",
      provider_thread_ref: %{
        "context_message_id" => "wamid.HBgM",
        "message_timestamp_ms" => DateTime.to_unix(quoted_at, :millisecond)
      },
      now: checked_at
    }

    assert {:ok, target} =
             ChannelThread.resolve_reply_target(ref, %{
               threading: :reply_chain,
               reply_key_type: :opaque_id,
               quote_ttl_ms: 86_400_000
             })

    assert target.strategy == :flat_stream
    assert target.threading == :flat
    assert target.declared_threading == :reply_chain
    assert target.reply_key_type == :opaque_id
    assert target.degradation == :quote_ttl_expired
    assert target.quote_window.expired? == true
    assert target.quote_window.ttl_ms == 86_400_000

    assert target.provider_thread_key ==
             ChannelThread.provider_thread_key(ref.provider_thread_ref)
  end

  test "requires Signal identity links to use ACI UUIDs instead of phone numbers" do
    aci = "550e8400-e29b-41d4-a716-446655440000"

    attrs = %{
      link_id: "link_signal_alice",
      user_id: "alice",
      channel: "signal",
      receiver_account_ref: "signal:primary",
      external_user_id: aci
    }

    assert {:ok, link} = ChannelThread.link_identity(attrs)
    assert link.external_user_id == aci

    assert {:error, {:invalid_signal_identity, :aci_required}} =
             ChannelThread.link_identity(%{attrs | external_user_id: "+15551234567"})

    assert {:error, {:invalid_signal_identity, :aci_required}} =
             ChannelThread.link_identity(%{attrs | external_user_id: "pni:550e8400"})
  end

  test "identity links are explicit durable rows and duplicate-safe" do
    slack_attrs = %{
      link_id: "link_alice",
      user_id: "alice",
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      external_user_id: "U0123"
    }

    discord_attrs = %{
      link_id: "link_alice",
      user_id: "alice",
      channel: "discord",
      receiver_account_ref: "discord:app:123456:guild:987654321",
      external_user_id: "11111"
    }

    assert [] = ChannelThread.list_identity_links(%{link_id: "link_alice"})

    assert {:ok, link} = ChannelThread.link_identity(slack_attrs)
    assert {:ok, duplicate} = ChannelThread.link_identity(slack_attrs)
    assert duplicate.id == link.id

    conflicting = Map.put(slack_attrs, :user_id, "bob")
    assert {:error, {:identity_link_conflict, "alice"}} = ChannelThread.link_identity(conflicting)

    assert {:ok, _discord_link} = ChannelThread.link_identity(discord_attrs)

    assert [discord_link, slack_link] =
             ChannelThread.list_identity_links(%{link_id: "link_alice"})

    assert discord_link.channel == "discord"
    assert slack_link.channel == "slack"

    assert [slack_link] = ChannelThread.list_identity_links(%{user_id: "alice", channel: "slack"})

    assert Repo.aggregate(CrossChannelIdentityLink, :count, :id) == 2

    assert {:ok, removed} = ChannelThread.unlink_identity(slack_attrs)
    assert removed.id == slack_link.id
    assert {:error, :not_found} = ChannelThread.unlink_identity(slack_attrs)

    assert [remaining] = ChannelThread.list_identity_links(%{link_id: "link_alice"})
    assert remaining.channel == "discord"
  end

  test "runtime maps known provider thread refs and records inbound message refs" do
    install_runtime_runner()

    ref = slack_ref("1718040000.000400")

    assert {:ok, first} =
             Runtime.submit_user_input(%{
               text: "first slack turn",
               channel: "slack",
               user_id: "alice",
               channel_thread_ref: ref,
               provider_message_id: "user-1718040000.000401"
             })

    assert String.starts_with?(first.thread_id, "thr_")
    assert is_binary(first.user_message_id)
    assert is_binary(first.assistant_message_id)
    assert {:ok, first.thread_id} == ChannelThread.lookup_thread(ref)

    assert [inbound_ref] =
             Repo.all(
               from message_ref in ConversationMessageRef,
                 where: message_ref.provider_message_id == "user-1718040000.000401"
             )

    assert inbound_ref.direction == "in"
    assert inbound_ref.canonical_message_id == first.user_message_id
    assert inbound_ref.canonical_thread_id == first.thread_id

    assert {:ok, _outbound_ref} =
             ref
             |> Map.merge(%{
               canonical_thread_id: first.thread_id,
               canonical_message_id: first.assistant_message_id,
               provider_message_id: "bot-1718040000.000402",
               direction: :out
             })
             |> ChannelThread.record_message_ref()

    assert ChannelThread.echo?(%{
             channel: "slack",
             receiver_account_ref: "slack:T0123",
             provider_message_id: "bot-1718040000.000402"
           })

    assert {:ok, newer} =
             Runtime.submit_user_input(%{
               text: "newer unrelated thread",
               channel: "web",
               user_id: "alice",
               new_thread: true
             })

    assert newer.thread_id != first.thread_id

    assert {:ok, second} =
             Runtime.submit_user_input(%{
               text: "second slack turn",
               channel: "slack",
               user_id: "alice",
               channel_thread_ref: ref,
               provider_message_id: "user-1718040000.000403"
             })

    assert second.thread_id == first.thread_id
  end

  test "provider thread refs do not authorize cross-user thread access" do
    install_runtime_runner()

    assert {:ok, bob_thread} = Conversations.create_general_thread("bob", "Private")
    ref = slack_ref("1718040000.000500")

    assert {:ok, _linked} =
             ref
             |> Map.put(:canonical_thread_id, bob_thread.id)
             |> ChannelThread.link_thread()

    bob_thread_id = bob_thread.id

    assert {:error, {:thread_not_found, ^bob_thread_id}} =
             Runtime.submit_user_input(%{
               text: "try to enter bob thread",
               channel: "slack",
               user_id: "alice",
               channel_thread_ref: ref,
               provider_message_id: "user-1718040000.000501"
             })

    assert [] = Conversations.list_threads("alice")
  end

  defp slack_ref(thread_ts) do
    %{
      channel: "slack",
      receiver_account_ref: "slack:T0123",
      provider_thread_ref: %{
        team_id: "T0123",
        channel_id: "C0123",
        thread_ts: thread_ts
      }
    }
  end

  defp install_runtime_runner do
    runner = fn _signal, request ->
      {:ok,
       %{
         message: "Runtime response: #{request.text}",
         status: :completed,
         actions: []
       }}
    end

    Application.put_env(:allbert_assist, Runtime, agent_runner: runner)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
