defmodule AllbertAssist.Channels.NotifyEditTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Channels.NotifyAudit
  alias AllbertAssist.Channels.NotifyDelivery
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.TestSupport.ShippedRegistries

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)

    root =
      Path.join(System.tmp_dir!(), "allbert-notify-edit-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    ShippedRegistries.restore!()
    Fragments.clear_cache()

    on_exit(fn ->
      restore_env(Paths, original_paths)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "status edit state restores from the ledger and append fallback replaces the id" do
    parent = fanout!()
    enable_notify!()
    put!("channels.telegram.autonomous_notify.level", "status_and_completion")
    put!("channels.telegram.autonomous_notify.min_interval_seconds", 5)
    test_pid = self()

    assert {:ok, first} =
             Notify.deliver(parent, :status, "started",
               delivery_key: "edit-first",
               outbound_fun: fn _, _, _, _ -> {:ok, %{message_id: "status-1"}} end
             )

    backdate!(first)

    assert {:ok, edited} =
             Notify.deliver(parent, :status, "working",
               delivery_key: "edit-second",
               edit_fun: fn channel, target, message_id, body, _opts ->
                 send(test_pid, {:edited, channel, target, message_id, body})
                 {:ok, %{message_id: message_id}}
               end,
               outbound_fun: fn _, _, _, _ -> flunk("edit must not append") end
             )

    assert edited.provider_message_id == "status-1"
    assert_receive {:edited, "telegram", "1007", "status-1", "working"}
    backdate!(edited)

    assert {:ok, fallback} =
             Notify.deliver(parent, :status, "still working",
               delivery_key: "edit-third",
               edit_fun: fn _, _, "status-1", _, _ -> {:error, :message_gone} end,
               outbound_fun: fn _, _, _, _ -> {:ok, %{message_id: "status-2"}} end
             )

    assert fallback.state == "delivered"
    assert fallback.provider_message_id == "status-2"
    assert fallback.error_class =~ "edit_fallback"
    backdate!(fallback)

    assert {:ok, resumed} =
             Notify.deliver(parent, :status, "resumed after restart",
               delivery_key: "edit-fourth",
               edit_fun: fn _, _, message_id, _, _ ->
                 send(test_pid, {:resumed_edit_id, message_id})
                 {:ok, %{message_id: message_id}}
               end
             )

    assert resumed.provider_message_id == "status-2"
    assert_receive {:resumed_edit_id, "status-2"}

    audit = File.read!(NotifyAudit.audit_path())
    assert audit =~ "edit_fallback"
  end

  test "uncertain edits do not append and completion always creates a new message" do
    parent = fanout!()
    enable_notify!()
    put!("channels.telegram.autonomous_notify.level", "status_and_completion")
    put!("channels.telegram.autonomous_notify.min_interval_seconds", 5)

    assert {:ok, first} =
             Notify.deliver(parent, :status, "started",
               delivery_key: "uncertain-first",
               outbound_fun: fn _, _, _, _ -> {:ok, %{message_id: "status-uncertain"}} end
             )

    backdate!(first)

    assert {:ok, uncertain} =
             Notify.deliver(parent, :status, "working",
               delivery_key: "uncertain-edit",
               edit_fun: fn _, _, _, _, _ -> {:error, {:uncertain, :timeout_after_write}} end,
               outbound_fun: fn _, _, _, _ -> flunk("uncertain edit must not append") end
             )

    assert uncertain.state == "uncertain"

    assert {:ok, completion} =
             Notify.deliver(parent, :completion, "done",
               delivery_key: "completion-is-new",
               edit_fun: fn _, _, _, _, _ -> flunk("completion must never edit") end,
               outbound_fun: fn _, _, _, _ -> {:ok, %{message_id: "completion-new"}} end
             )

    assert completion.provider_message_id == "completion-new"

    assert {:ok, confirmation} =
             Notify.deliver(parent, :confirmation_request, "approve confirm-1",
               delivery_key: "confirmation-is-new",
               edit_fun: fn _, _, _, _, _ -> flunk("confirmation must never edit") end,
               outbound_fun: fn _, _, _, _ -> {:ok, %{message_id: "confirmation-new"}} end
             )

    assert confirmation.provider_message_id == "confirmation-new"
  end

  test "provider-specific receipt ids normalize into restart-safe ledger state" do
    parent = fanout!()
    enable_notify!()

    receipts = [
      {%{result: %{"message_id" => 101}}, "101"},
      {%{result: %{"id" => "discord-1"}}, "discord-1"},
      {%{result: %{"ts" => "1718040000.000100"}}, "1718040000.000100"},
      {%{event_id: "$matrix-1"}, "$matrix-1"}
    ]

    for {receipt, expected} <- receipts do
      assert {:ok, delivery} =
               Notify.deliver(parent, :completion, "done",
                 delivery_key: "receipt-#{expected}",
                 outbound_fun: fn _, _, _, _ -> {:ok, receipt} end
               )

      assert delivery.provider_message_id == expected
    end
  end

  defp backdate!(delivery) do
    delivery
    |> NotifyDelivery.changeset(%{throttle_at: DateTime.add(DateTime.utc_now(), -10, :second)})
    |> Repo.update!()
  end

  defp fanout! do
    {:ok, thread} = Conversations.create_general_thread("alice", "notify edit")

    {:ok, ref} =
      ChannelThread.link_thread(%{
        canonical_thread_id: thread.id,
        channel: "telegram",
        receiver_account_ref: "telegram:bot:test",
        provider_thread_ref: %{
          "provider" => "telegram",
          "chat_id" => "1007",
          "origin_identity_digest" => ChannelThread.identity_digest("alice-ext")
        }
      })

    digest =
      %{
        id: to_string(ref.id),
        owner_scope: ref.owner_scope,
        channel: ref.channel,
        receiver_account_ref: ref.receiver_account_ref,
        provider_thread_key: ref.provider_thread_key,
        provider_thread_ref: ref.provider_thread_ref,
        trust_class: ref.trust_class
      }
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, %{parent: parent}} =
      Fanout.frame(
        %{
          user_id: "alice",
          title: "Edit fan-out",
          objective: "Do two things",
          source_thread_id: thread.id,
          source_channel: "telegram",
          source_surface: "channel",
          origin_thread_ref_id: to_string(ref.id),
          origin_thread_ref_digest: digest,
          origin_receiver_account_ref: ref.receiver_account_ref
        },
        ["One", "Two"]
      )

    parent
  end

  defp enable_notify! do
    put!("channels.telegram.identity_map", [
      %{"external_user_id" => "alice-ext", "user_id" => "alice", "enabled" => true}
    ])

    put!("channels.telegram.autonomous_notify.enabled", true)
  end

  defp put!(key, value), do: assert({:ok, _setting} = Settings.put(key, value, %{audit?: false}))

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
