defmodule AllbertAssist.Channels.NotifyTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Channels.NotifyAudit
  alias AllbertAssist.Channels.NotifyConsentCallback
  alias AllbertAssist.Channels.NotifyConsumer
  alias AllbertAssist.Channels.NotifyDelivery
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Signals
  alias AllbertAssist.TestSupport.ShippedRegistries
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_notify = Application.get_env(:allbert_assist, Notify)

    root =
      Path.join(System.tmp_dir!(), "allbert-notify-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    ShippedRegistries.restore!()
    Fragments.clear_cache()

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Notify, original_notify)
      ShippedRegistries.restore!()
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "default off suppresses without transport and records a redacted audit" do
    parent = fanout!("alice", "1001")

    assert {:ok, delivery} =
             Notify.deliver(parent, :completion, "secret sk-test-1234567890123456",
               outbound_fun: fn _, _, _, _ -> flunk("transport must not run") end
             )

    assert delivery.state == "suppressed"
    assert delivery.error_class =~ "notify_disabled"

    audit = File.read!(NotifyAudit.audit_path())
    assert audit =~ "notify_disabled"
    refute audit =~ "sk-test"
  end

  test "opt-in delivers redacted completion to the exact current origin" do
    parent = fanout!("alice", "1002")
    enable_notify!("alice-ext")
    test_pid = self()

    assert {:ok, delivery} =
             Notify.deliver(parent, :completion, "done api_key=sk-test-1234567890123456",
               outbound_fun: fn channel, target, body, opts ->
                 send(test_pid, {:sent, channel, target, body, opts})
                 {:ok, %{message_id: "provider-1"}}
               end
             )

    assert delivery.state == "delivered"
    assert delivery.provider_message_id == "provider-1"
    assert_receive {:sent, "telegram", "1002", body, [thread: thread]}
    refute body =~ "sk-test"
    assert thread["chat_id"] == "1002"
  end

  test "status level and throttle suppress independently" do
    parent = fanout!("alice", "1003")
    enable_notify!("alice-ext")

    assert {:ok, level_denied} =
             Notify.deliver(parent, :status, "working", delivery_key: "status-level")

    assert level_denied.error_class =~ "status_level_disabled"

    put!("channels.telegram.autonomous_notify.level", "status_and_completion")
    outbound = fn _, _, _, _ -> {:ok, %{message_id: Ecto.UUID.generate()}} end

    assert {:ok, first} =
             Notify.deliver(parent, :status, "working",
               delivery_key: "status-first",
               outbound_fun: outbound
             )

    assert first.state == "delivered"

    assert {:ok, throttled} =
             Notify.deliver(parent, :status, "still working",
               delivery_key: "status-second",
               outbound_fun: outbound
             )

    assert throttled.error_class =~ "throttled"
  end

  test "confirmation requests deliver at completion level and remain idempotent" do
    parent = fanout!("alice", "1003-confirm")
    enable_notify!("alice-ext")
    test_pid = self()

    outbound = fn _, _, body, _ ->
      send(test_pid, {:confirmation_body, body})
      {:ok, %{message_id: "confirmation-provider-id"}}
    end

    assert {:ok, first} =
             Notify.deliver(parent, :confirmation_request, "Reply ALLBERT:APPROVE:confirm-1",
               delivery_key: "confirmation-request-1",
               outbound_fun: outbound
             )

    assert first.state == "delivered"
    assert_receive {:confirmation_body, "Reply ALLBERT:APPROVE:confirm-1"}

    assert {:ok, duplicate} =
             Notify.deliver(parent, :confirmation_request, "duplicate",
               delivery_key: "confirmation-request-1",
               outbound_fun: fn _, _, _, _ -> flunk("terminal notification must deduplicate") end
             )

    assert duplicate.id == first.id
  end

  test "identity removal and uncertain sends fail closed without retry" do
    parent = fanout!("alice", "1004")
    enable_notify!("alice-ext")
    put!("channels.telegram.identity_map", [])

    assert {:ok, denied} =
             Notify.deliver(parent, :completion, "done", delivery_key: "identity-denied")

    assert denied.error_class =~ "identity_not_mapped"

    put!("channels.telegram.identity_map", [identity("remapped-ext", "alice")])

    assert {:ok, remapped} =
             Notify.deliver(parent, :completion, "done", delivery_key: "identity-remapped")

    assert remapped.error_class =~ "origin_identity_remapped"

    put!("channels.telegram.identity_map", [identity("alice-ext", "alice")])

    assert {:ok, uncertain} =
             Notify.deliver(parent, :completion, "done",
               delivery_key: "uncertain-send",
               outbound_fun: fn _, _, _, _ -> {:error, {:uncertain, :timeout_after_write}} end
             )

    assert uncertain.state == "uncertain"

    assert {:ok, same} =
             Notify.deliver(parent, :completion, "done",
               delivery_key: "uncertain-send",
               outbound_fun: fn _, _, _, _ -> flunk("uncertain send must not retry") end
             )

    assert same.id == uncertain.id
  end

  test "definitive transport failure receives exactly one bounded retry" do
    parent = fanout!("alice", "1004-retry")
    enable_notify!("alice-ext")
    test_pid = self()

    failing = fn _, _, _, _ ->
      send(test_pid, :attempted)
      {:error, :connection_refused}
    end

    assert {:ok, first} =
             Notify.deliver(parent, :completion, "done",
               delivery_key: "definitive-retry",
               outbound_fun: failing
             )

    assert first.state == "failed"
    assert first.attempt_count == 1

    assert {:ok, second} =
             Notify.deliver(parent, :completion, "done",
               delivery_key: "definitive-retry",
               outbound_fun: failing
             )

    assert second.id == first.id
    assert second.state == "failed"
    assert second.attempt_count == 2

    assert {:ok, terminal} =
             Notify.deliver(parent, :completion, "done",
               delivery_key: "definitive-retry",
               outbound_fun: fn _, _, _, _ -> flunk("third transport attempt is forbidden") end
             )

    assert terminal.id == first.id
    assert terminal.attempt_count == 2
    assert_received :attempted
    assert_received :attempted
    refute_received :attempted
  end

  test "typed consent re-proves identity and the delivered offer never repeats" do
    parent = fanout!("alice", "1005")
    put!("channels.telegram.identity_map", [identity("alice-ext", "alice")])

    assert Notify.prepare_consent_offer(parent)

    assert :ok =
             Notify.mark_consent_offer_delivered(%{channel: "telegram", user_id: "alice"})

    refute Notify.prepare_consent_offer(parent)

    refute NotifyConsentCallback.typed_command?("please enable ALLBERT:NOTIFY:ON")
    refute NotifyConsentCallback.typed_command?("allbert:notify:on")
    assert NotifyConsentCallback.typed_command?("ALLBERT:NOTIFY:ON")

    request = %{
      channel: "telegram",
      user_id: "alice",
      operator_id: "alice",
      metadata: %{external_user_id: "alice-ext"}
    }

    assert {:ok, %{status: :completed}} = NotifyConsentCallback.run(request)
    assert {:ok, true} = Settings.get("channels.telegram.autonomous_notify.enabled")
    refute Notify.prepare_consent_offer(parent)

    assert {:ok, %{status: :completed}} =
             NotifyConsentCallback.run(%{
               channel: "telegram",
               user_id: "alice",
               resolver_metadata: %{external_user_id: "alice-ext"}
             })

    assert {:error, :wrong_user} =
             NotifyConsentCallback.run(%{request | user_id: "mallory", operator_id: "mallory"})
  end

  test "email settings clamp status delivery and every channel defaults off" do
    for channel <- ~w[telegram email discord slack matrix whatsapp signal tui] do
      assert {:ok, false} = Settings.get("channels.#{channel}.autonomous_notify.enabled")

      assert {:ok, 30} =
               Settings.get("channels.#{channel}.autonomous_notify.min_interval_seconds")
    end

    assert {:error, _reason} =
             Settings.put("channels.email.autonomous_notify.level", "status_and_completion", %{
               audit?: false
             })
  end

  test "signal consumer autonomously delivers completion and consumes its report receipt" do
    parent = fanout!("alice", "1006")
    enable_notify!("alice-ext")
    test_pid = self()

    Application.put_env(:allbert_assist, Notify,
      outbound_fun: fn channel, target, body, opts ->
        send(test_pid, {:consumer_sent, channel, target, body, opts})
        {:ok, %{message_id: "consumer-provider-id"}}
      end
    )

    consumer = start_supervised!({NotifyConsumer, name: nil})
    Sandbox.allow(Repo, self(), consumer)

    for child <- Fanout.children(parent) do
      assert {:ok, _child} =
               Objectives.update_objective(child, %{
                 status: "completed",
                 last_observation_summary: "done",
                 completed_at: DateTime.utc_now()
               })
    end

    assert {:ok, %{parent: joined}} = Fanout.finalize_join(parent)
    Signals.emit_fanout(:fanout_joined, %{parent_id: joined.id})

    assert_receive {:consumer_sent, "telegram", "1006", body, _opts}, 2_000
    assert body =~ "Notify fan-out"

    assert eventually(fn -> Objectives.get_objective(joined.id) end).report_delivery_state ==
             "delivered"

    assert Repo.get_by!(NotifyDelivery, fanout_id: joined.id, kind: "completion").state ==
             "delivered"
  end

  defp fanout!(user_id, chat_id) do
    {:ok, thread} = Conversations.create_general_thread(user_id, "notify")

    {:ok, ref} =
      ChannelThread.link_thread(%{
        canonical_thread_id: thread.id,
        channel: "telegram",
        receiver_account_ref: "telegram:bot:test",
        provider_thread_ref: %{
          "provider" => "telegram",
          "chat_id" => chat_id,
          "origin_identity_digest" => ChannelThread.identity_digest("alice-ext")
        }
      })

    ref_map = %{
      id: to_string(ref.id),
      owner_scope: ref.owner_scope,
      channel: ref.channel,
      receiver_account_ref: ref.receiver_account_ref,
      provider_thread_key: ref.provider_thread_key,
      provider_thread_ref: ref.provider_thread_ref,
      trust_class: ref.trust_class
    }

    digest =
      ref_map
      |> Jason.encode!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    {:ok, %{parent: parent}} =
      Fanout.frame(
        %{
          user_id: user_id,
          title: "Notify fan-out",
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

  defp enable_notify!(external_user_id) do
    put!("channels.telegram.identity_map", [identity(external_user_id, "alice")])
    put!("channels.telegram.autonomous_notify.enabled", true)
  end

  defp identity(external_user_id, user_id),
    do: %{"external_user_id" => external_user_id, "user_id" => user_id, "enabled" => true}

  defp put!(key, value) do
    assert {:ok, _setting} = Settings.put(key, value, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)

  defp eventually(fun, attempts \\ 40)
  defp eventually(fun, 0), do: elem(fun.(), 1)

  defp eventually(fun, attempts) do
    case fun.() do
      {:ok, %{report_delivery_state: "delivered"} = value} ->
        value

      _other ->
        Process.sleep(25)
        eventually(fun, attempts - 1)
    end
  end
end
