defmodule AllbertAssist.Channels.NotifyTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.TestSupport.EffectGuardStubs.Recording, as: EpochGuard

  import Ecto.Query

  alias AllbertAssist.Channels.Notify
  alias AllbertAssist.Channels.NotifyAudit
  alias AllbertAssist.Channels.NotifyConsentCallback
  alias AllbertAssist.Channels.NotifyConsumer
  alias AllbertAssist.Channels.NotifyDelivery
  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.ChannelThread
  alias AllbertAssist.Conversations.ThreadChannelRef
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Signals
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias Ecto.Adapters.SQL.Sandbox
  alias Jido.Signal.Bus

  setup {Req.Test, :verify_on_exit!}

  defmodule ReadyEpochGuard do
    alias AllbertAssist.Pack.EffectGuard

    def admit_ready(server), do: EffectGuard.admit_ready(server: server)
    def validate(_server, epoch), do: EffectGuard.validate(epoch)
  end

  defmodule ReplacingBarrier do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts) do
      {:ok,
       %{
         calls: 0,
         replace_on: Keyword.fetch!(opts, :replace_on),
         active: spawn(fn -> Process.sleep(:infinity) end),
         replacement: spawn(fn -> Process.sleep(:infinity) end)
       }}
    end

    @impl true
    def handle_call(:status, _from, state) do
      calls = state.calls + 1
      barrier_pid = if calls >= state.replace_on, do: state.replacement, else: state.active

      {:reply,
       {:ok,
        %{
          phase: :ready,
          barrier_pid: barrier_pid,
          snapshot_digest: String.duplicate("r", 64),
          expected_ids: [],
          subscribed_ids: [],
          acked_ids: [],
          diagnostics: []
        }}, %{state | calls: calls}}
    end

    @impl true
    def terminate(_reason, state) do
      Process.exit(state.active, :kill)
      Process.exit(state.replacement, :kill)
    end
  end

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_notify = Application.get_env(:allbert_assist, Notify)
    original_settings = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-notify-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Fragments.clear_cache()
    assert Settings.root() == Path.join(root, "settings")

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Notify, original_notify)
      restore_env(Settings, original_settings)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "default off suppresses without transport and records a redacted audit" do
    parent = fanout!("alice", "1001")

    assert {:ok, delivery} =
             deliver_ready(parent, :completion, "secret sk-test-1234567890123456",
               outbound_fun: fn _, _, _, _ -> flunk("transport must not run") end
             )

    assert delivery.state == "suppressed"
    assert delivery.error_class =~ "notify_disabled"

    audit = File.read!(NotifyAudit.audit_path())
    assert audit =~ "notify_disabled"
    refute audit =~ "sk-test"
  end

  test "autonomous delivery refuses to reserve without a carried epoch" do
    parent = fanout!("alice", "1001-no-epoch")

    assert {:error, :product_not_ready} =
             Notify.deliver(parent, :completion, "must not reserve",
               outbound_fun: fn _, _, _, _ -> flunk("transport must not run") end
             )

    refute Repo.get_by(NotifyDelivery, fanout_id: parent.id)
  end

  test "same-digest replacement immediately before provider dispatch stops transport" do
    parent = fanout!("alice", "1001-provider-race")
    enable_notify!("alice-ext")
    barrier = start_supervised!({ReplacingBarrier, replace_on: 4})
    assert {:ok, epoch} = AllbertAssist.Pack.EffectGuard.admit_ready(server: barrier)

    assert {:error, :stale_epoch} =
             Notify.deliver(parent, :completion, "must not send",
               allbert_pack_epoch: epoch,
               delivery_key: "provider-race",
               outbound_fun: fn _, _, _, _ -> flunk("stale E1 must not reach transport") end
             )

    assert %NotifyDelivery{state: "sending"} =
             Repo.get_by(NotifyDelivery, delivery_key: "provider-race")
  end

  test "same-digest replacement after provider dispatch prevents E1 settlement" do
    parent = fanout!("alice", "1001-settlement-race")
    enable_notify!("alice-ext")
    effect_context = ReadyEffectContext.context()
    server = ReadyEffectContext.server(effect_context)
    test_pid = self()

    assert {:error, :stale_epoch} =
             Notify.deliver(parent, :completion, "provider already accepted",
               allbert_pack_epoch: effect_context.allbert_pack_epoch,
               delivery_key: "settlement-race",
               outbound_fun: fn _, _, _, opts ->
                 send(test_pid, {:provider_called, opts})
                 :ok = ReadyEffectContext.replace(server)
                 {:ok, %{message_id: "provider-race-1"}}
               end,
               audit_fun: fn _, _, _, _ -> flunk("stale E1 must not append audit") end
             )

    assert_receive {:provider_called, opts}
    assert opts[:allbert_pack_epoch] == effect_context.allbert_pack_epoch

    assert %NotifyDelivery{state: "sending", provider_message_id: nil} =
             Repo.get_by(NotifyDelivery, delivery_key: "settlement-race")
  end

  test "opt-in delivers redacted completion to the exact current origin" do
    parent = fanout!("alice", "1002")
    enable_notify!("alice-ext")
    test_pid = self()

    assert {:ok, delivery} =
             deliver_ready(parent, :completion, "done api_key=sk-test-1234567890123456",
               outbound_fun: fn channel, target, body, opts ->
                 send(test_pid, {:sent, channel, target, body, opts})
                 {:ok, %{message_id: "provider-1"}}
               end
             )

    assert delivery.state == "delivered"
    assert delivery.provider_message_id == "provider-1"
    assert_receive {:sent, "telegram", "1002", body, opts}
    thread = Keyword.fetch!(opts, :thread)
    epoch = Keyword.fetch!(opts, :allbert_pack_epoch)
    assert is_pid(epoch.barrier_pid)
    refute body =~ "sk-test"
    assert thread["chat_id"] == "1002"
  end

  test "default Outbound dispatch carries the exact epoch into the real adapter" do
    parent = fanout!("alice", "1002-real-adapter")
    enable_notify!("alice-ext")

    assert {:ok, _secret} =
             Secrets.put_secret(
               "secret://channels/telegram/bot_token",
               "token",
               ReadyEffectContext.attach(%{audit?: false})
             )

    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.method == "POST"
      assert conn.request_path == "/bottoken/sendMessage"

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"ok" => true, "result" => %{"message_id" => 202}})
      )
    end)

    assert {:ok, delivery} =
             deliver_ready(parent, :completion, "real adapter",
               req_options: [plug: {Req.Test, __MODULE__}],
               delivery_key: "default-outbound-real-adapter"
             )

    assert delivery.state == "delivered"
    assert delivery.provider_message_id == "202"
  end

  test "mutable provider metadata preserves the stable origin while key remapping suppresses" do
    parent = fanout!("alice", "1002-stable")
    enable_notify!("alice-ext")
    ref_id = String.to_integer(parent.origin_thread_ref_id)
    ref = Repo.get!(ThreadChannelRef, ref_id)

    assert {:ok, updated_ref} =
             ChannelThread.link_thread(%{
               canonical_thread_id: ref.canonical_thread_id,
               channel: ref.channel,
               receiver_account_ref: ref.receiver_account_ref,
               provider_thread_key: ref.provider_thread_key,
               provider_thread_ref:
                 Map.merge(ref.provider_thread_ref, %{
                   "message_id" => "later-provider-message",
                   "reply_depth" => 4
                 })
             })

    assert updated_ref.id == ref.id
    assert ChannelThread.canonical_ref_digest(updated_ref) == parent.origin_thread_ref_digest

    assert {:ok, delivered} =
             deliver_ready(parent, :completion, "stable delivery",
               delivery_key: "stable-origin-delivery",
               outbound_fun: fn _channel, _target, _body, opts ->
                 assert opts[:thread]["message_id"] == "later-provider-message"
                 {:ok, %{message_id: "stable-provider-id"}}
               end
             )

    assert delivered.state == "delivered"

    assert {1, _rows} =
             ThreadChannelRef
             |> where([thread_ref], thread_ref.id == ^ref.id)
             |> Repo.update_all(set: [provider_thread_key: "remapped-provider-key"])

    assert {:ok, suppressed} =
             deliver_ready(parent, :completion, "must not deliver",
               delivery_key: "remapped-origin-delivery",
               outbound_fun: fn _, _, _, _ ->
                 flunk("remapped origin must not reach transport")
               end
             )

    assert suppressed.state == "suppressed"
    assert suppressed.error_class =~ "origin_thread_ref_mismatch"
  end

  test "status level and throttle suppress independently" do
    parent = fanout!("alice", "1003")
    enable_notify!("alice-ext")

    assert {:ok, level_denied} =
             deliver_ready(parent, :status, "working", delivery_key: "status-level")

    assert level_denied.error_class =~ "status_level_disabled"

    put!("channels.telegram.autonomous_notify.level", "status_and_completion")
    outbound = fn _, _, _, _ -> {:ok, %{message_id: Ecto.UUID.generate()}} end

    assert {:ok, first} =
             deliver_ready(parent, :status, "working",
               delivery_key: "status-first",
               outbound_fun: outbound
             )

    assert first.state == "delivered"

    assert {:ok, throttled} =
             deliver_ready(parent, :status, "still working",
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
             deliver_ready(parent, :confirmation_request, "Reply ALLBERT:APPROVE:confirm-1",
               delivery_key: "confirmation-request-1",
               outbound_fun: outbound
             )

    assert first.state == "delivered"
    assert_receive {:confirmation_body, "Reply ALLBERT:APPROVE:confirm-1"}

    assert {:ok, duplicate} =
             deliver_ready(parent, :confirmation_request, "duplicate",
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
             deliver_ready(parent, :completion, "done", delivery_key: "identity-denied")

    assert denied.error_class =~ "identity_not_mapped"

    put!("channels.telegram.identity_map", [identity("remapped-ext", "alice")])

    assert {:ok, remapped} =
             deliver_ready(parent, :completion, "done", delivery_key: "identity-remapped")

    assert remapped.error_class =~ "origin_identity_remapped"

    put!("channels.telegram.identity_map", [identity("alice-ext", "alice")])

    assert {:ok, uncertain} =
             deliver_ready(parent, :completion, "done",
               delivery_key: "uncertain-send",
               outbound_fun: fn _, _, _, _ -> {:error, {:uncertain, :timeout_after_write}} end
             )

    assert uncertain.state == "uncertain"

    assert {:ok, same} =
             deliver_ready(parent, :completion, "done",
               delivery_key: "uncertain-send",
               outbound_fun: fn _, _, _, _ -> flunk("uncertain send must not retry") end
             )

    assert same.id == uncertain.id
  end

  test "transport raises and exits are quarantined as uncertain without retry" do
    parent = fanout!("alice", "1004-transport-exception")
    enable_notify!("alice-ext")

    for {key, outbound_fun} <- [
          {"raising-send", fn _, _, _, _ -> raise "transport exploded" end},
          {"exiting-send", fn _, _, _, _ -> exit(:transport_exited) end}
        ] do
      assert {:ok, %{state: "uncertain", attempt_count: 1} = uncertain} =
               deliver_ready(parent, :completion, "done",
                 delivery_key: key,
                 outbound_fun: outbound_fun
               )

      assert {:ok, same} =
               deliver_ready(parent, :completion, "done",
                 delivery_key: key,
                 outbound_fun: fn _, _, _, _ -> flunk("uncertain transport must not retry") end
               )

      assert same.id == uncertain.id
      assert same.state == "uncertain"
    end
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
             deliver_ready(parent, :completion, "done",
               delivery_key: "definitive-retry",
               outbound_fun: failing
             )

    assert first.state == "failed"
    assert first.attempt_count == 1

    assert {:ok, second} =
             deliver_ready(parent, :completion, "done",
               delivery_key: "definitive-retry",
               outbound_fun: failing
             )

    assert second.id == first.id
    assert second.state == "failed"
    assert second.attempt_count == 2

    assert {:ok, terminal} =
             deliver_ready(parent, :completion, "done",
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
    effect_context = ReadyEffectContext.context()

    assert prepare_consent_offer_ready(parent)

    assert :ok =
             Notify.mark_consent_offer_delivered(
               %{channel: "telegram", user_id: "alice"},
               effect_context
             )

    refute prepare_consent_offer_ready(parent)

    refute NotifyConsentCallback.typed_command?("please enable ALLBERT:NOTIFY:ON")
    refute NotifyConsentCallback.typed_command?("allbert:notify:on")
    assert NotifyConsentCallback.typed_command?("ALLBERT:NOTIFY:ON")

    request = %{
      channel: "telegram",
      user_id: "alice",
      operator_id: "alice",
      allbert_pack_epoch: effect_context.allbert_pack_epoch,
      metadata: %{external_user_id: "alice-ext"}
    }

    assert {:ok, %{status: :completed}} = NotifyConsentCallback.run(request)
    assert {:ok, true} = Settings.get("channels.telegram.autonomous_notify.enabled")
    refute prepare_consent_offer_ready(parent)

    assert {:ok, %{status: :completed}} =
             NotifyConsentCallback.run(%{
               channel: "telegram",
               user_id: "alice",
               allbert_pack_epoch: effect_context.allbert_pack_epoch,
               resolver_metadata: %{external_user_id: "alice-ext"}
             })

    assert {:error, :wrong_user} =
             NotifyConsentCallback.run(%{request | user_id: "mallory", operator_id: "mallory"})
  end

  test "non-completed consent action leaves the durable offer pending" do
    parent = fanout!("alice", "1005-stale-consent")
    put!("channels.telegram.identity_map", [identity("alice-ext", "alice")])
    effect_context = ReadyEffectContext.context()

    assert Notify.prepare_consent_offer(parent, effect_context)

    assert :ok =
             Notify.mark_consent_offer_delivered(
               %{channel: "telegram", user_id: "alice"},
               effect_context
             )

    server = ReadyEffectContext.server(effect_context)
    assert :ok = ReadyEffectContext.replace(server)

    assert {:error, {:setting_not_completed, :unavailable}} =
             NotifyConsentCallback.run(%{
               channel: "telegram",
               user_id: "alice",
               allbert_pack_epoch: effect_context.allbert_pack_epoch,
               metadata: %{external_user_id: "alice-ext"}
             })

    assert %NotifyDelivery{offer_state: "delivered"} =
             Repo.get_by(NotifyDelivery,
               fanout_id: parent.id,
               kind: "consent_offer"
             )
  end

  test "email settings clamp status delivery and every channel defaults off" do
    for channel <- ~w[telegram email discord slack matrix whatsapp signal tui] do
      assert {:ok, false} = Settings.get("channels.#{channel}.autonomous_notify.enabled")

      assert {:ok, 30} =
               Settings.get("channels.#{channel}.autonomous_notify.min_interval_seconds")
    end

    assert {:error, _reason} =
             Settings.put(
               "channels.email.autonomous_notify.level",
               "status_and_completion",
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{
                 audit?: false
               })
             )
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

    consumer = start_ready_consumer(name: nil)
    Sandbox.allow(Repo, self(), consumer)

    children = Fanout.children(parent)
    FanoutReportFixture.complete_children!(children)

    %{parent: joined} =
      FanoutReportFixture.select_completed!(%{parent: parent, children: children}, :fallback)

    assert_receive {:consumer_sent, "telegram", "1006", body, _opts}, 2_000
    assert body == Fanout.format_report(Fanout.report(joined))

    assert eventually(fn -> Objectives.get_objective(joined.id) end).report_delivery_state ==
             "delivered"

    assert Repo.get_by!(NotifyDelivery, fanout_id: joined.id, kind: "completion").state ==
             "delivered"
  end

  test "attached local status produces no autonomous ledger or audit writes" do
    {:ok, %{parent: parent}} =
      Fanout.frame(
        %{
          user_id: "alice",
          title: "Attached fan-out",
          objective: "Do two things",
          source_channel: "tui",
          source_surface: "tui"
        }
        |> Map.merge(ReadyEffectContext.context()),
        ["One", "Two"]
      )

    for index <- 1..100 do
      assert {:ok, :attached_surface} =
               deliver_ready(parent, :status, "progress #{index}", event_key: "sig-#{index}")
    end

    refute Repo.exists?(from delivery in NotifyDelivery, where: delivery.fanout_id == ^parent.id)
    refute File.exists?(NotifyAudit.audit_path())
  end

  test "in-band local and public-protocol surfaces never enter autonomous delivery bookkeeping" do
    for channel <- ~w[tui web live_view cli acp_stdio openai_api job] do
      assert {:ok, %{parent: parent}} =
               Fanout.frame(
                 %{
                   user_id: "surface-#{channel}",
                   title: "#{channel} fan-out",
                   objective: "Stay in-band",
                   source_channel: channel,
                   source_thread_id: "thread-#{channel}"
                 }
                 |> Map.merge(ReadyEffectContext.context()),
                 ["one", "two"]
               )

      assert {:ok, :attached_surface} =
               deliver_ready(parent, :completion, "completion",
                 outbound_fun: fn _, _, _, _ ->
                   flunk("#{channel} must not use autonomous transport")
                 end
               )

      refute Repo.exists?(
               from delivery in NotifyDelivery, where: delivery.fanout_id == ^parent.id
             )
    end
  end

  test "disabled and completion-only status decisions are each coalesced before reservation" do
    disabled = fanout!("alice", "1008")

    for index <- 1..100 do
      assert {:ok, %{state: "suppressed"}} =
               deliver_ready(disabled, :status, "progress #{index}", event_key: "off-#{index}")
    end

    assert Repo.aggregate(
             from(delivery in NotifyDelivery,
               where: delivery.fanout_id == ^disabled.id and delivery.kind == "status"
             ),
             :count
           ) == 1

    completion_only = fanout!("alice", "1009")
    enable_notify!("alice-ext")

    for index <- 1..100 do
      assert {:ok, %{state: "suppressed"}} =
               deliver_ready(completion_only, :status, "progress #{index}",
                 event_key: "completion-only-#{index}"
               )
    end

    assert Repo.aggregate(
             from(delivery in NotifyDelivery,
               where: delivery.fanout_id == ^completion_only.id and delivery.kind == "status"
             ),
             :count
           ) == 1

    audit = File.read!(NotifyAudit.audit_path())
    assert length(Regex.scan(~r/^## .* suppressed$/m, audit)) == 2
  end

  test "completion recovery resumes reserved, quarantines sending, and preserves delivered" do
    enable_notify!("alice-ext")
    test_pid = self()

    reserved = fanout!("alice", "1010") |> join_parent!()
    insert_completion_delivery!(reserved, "reserved", 0)

    assert {:ok, %{state: "delivered", attempt_count: 1}} =
             recover_completion_ready(reserved,
               outbound_fun: fn _, _, _, _ ->
                 send(test_pid, {:recovery_transport, reserved.id})
                 {:ok, %{message_id: "reserved-provider"}}
               end
             )

    assert_receive {:recovery_transport, reserved_id}
    assert reserved_id == reserved.id

    sending = fanout!("alice", "1011") |> join_parent!()
    insert_completion_delivery!(sending, "sending", 1)

    assert {:ok, %{state: "uncertain"}} =
             recover_completion_ready(sending,
               outbound_fun: fn _, _, _, _ -> flunk("interrupted send must not retry") end
             )

    delivered = fanout!("alice", "1012") |> join_parent!()
    insert_completion_delivery!(delivered, "delivered", 1, "provider-done")

    assert {:ok, %{state: "delivered", provider_message_id: "provider-done"}} =
             recover_completion_ready(delivered,
               outbound_fun: fn _, _, _, _ -> flunk("delivered work must not resend") end
             )
  end

  test "completion delivery preserves both layout-v2 selection bodies exactly" do
    enable_notify!("alice-ext")
    test_pid = self()

    for source <- [:model, :fallback] do
      selected = selected_notify_report!(source, "1010-selected-body-#{source}")

      assert {:ok, %{state: "delivered"}} =
               recover_completion_ready(selected.parent,
                 outbound_fun: fn _, _, body, _ ->
                   send(test_pid, {:completion_body, source, body})
                   {:ok, %{message_id: "selected-body-provider-#{source}"}}
                 end
               )

      assert_receive {:completion_body, ^source, body}
      assert body == selected.report_body
    end
  end

  test "consumer startup replay sends one pending completion and only acknowledges once" do
    parent = fanout!("alice", "1013") |> join_parent!()
    enable_notify!("alice-ext")
    test_pid = self()

    consumer =
      start_ready_consumer(
        name: nil,
        retry_delay_ms: 25,
        notify_opts: [
          outbound_fun: fn _, _, _, _ ->
            send(test_pid, {:startup_replay_sent, parent.id})
            {:ok, %{message_id: "startup-provider"}}
          end
        ]
      )

    Sandbox.allow(Repo, self(), consumer)
    send(consumer, :reconcile_completion_outbox)

    assert_receive {:startup_replay_sent, parent_id}, 2_000
    assert parent_id == parent.id

    assert eventually(fn -> Objectives.get_objective(parent.id) end).report_delivery_state ==
             "delivered"

    send(consumer, :reconcile_completion_outbox)
    refute_receive {:startup_replay_sent, _parent_id}, 200
  end

  test "same-digest replacement skips completion replay before provider delivery" do
    parent = fanout!("alice", "1013-stale") |> join_parent!()
    enable_notify!("alice-ext")
    digest = String.duplicate("b", 64)
    barrier_one = spawn(fn -> Process.sleep(:infinity) end)
    barrier_two = spawn(fn -> Process.sleep(:infinity) end)
    epoch = %{barrier_pid: barrier_one, snapshot_digest: digest}
    test_pid = self()

    on_exit(fn ->
      if Process.alive?(barrier_one), do: Process.exit(barrier_one, :kill)
      if Process.alive?(barrier_two), do: Process.exit(barrier_two, :kill)
    end)

    guard =
      start_supervised!(
        {Agent,
         fn ->
           %{
             epoch: epoch,
             replacement: %{barrier_pid: barrier_two, snapshot_digest: digest},
             test_pid: test_pid,
             admit_count: 0,
             validate_count: 0,
             admitted_tag: :notify_epoch_admitted,
             validated_tag: :notify_epoch_validated
           }
         end}
      )

    consumer =
      start_ready_consumer(
        name: nil,
        effect_guard: {EpochGuard, guard},
        whereis_fun: fn _bus -> flunk("stale epoch must not look up the signal bus") end,
        notify_opts: [
          outbound_fun: fn _, _, _, _ ->
            flunk("stale epoch must not reach provider delivery")
          end
        ]
      )

    send(consumer, :reconcile_completion_outbox)

    assert_receive {:notify_epoch_admitted, ^epoch}, 1_000
    assert_receive {:notify_epoch_validated, ^epoch}, 1_000

    assert eventually_true(fn ->
             Agent.get(guard, &(&1.admit_count >= 2 and &1.validate_count >= 2))
           end)

    assert {:ok, pending} = Objectives.get_objective(parent.id)
    assert pending.report_delivery_state == "pending"
  end

  test "periodic durable reconcile delivers a selected pending report without a signal" do
    enable_notify!("alice-ext")
    test_pid = self()

    consumer =
      start_ready_consumer(
        name: nil,
        whereis_fun: fn _bus -> {:error, :bus_unavailable} end,
        reconcile_interval_ms: 1_000,
        notify_opts: [
          outbound_fun: fn _, _, body, _ ->
            send(test_pid, {:periodic_reconcile_sent, body})
            {:ok, %{message_id: "periodic-provider"}}
          end
        ]
      )

    Sandbox.allow(Repo, self(), consumer)
    parent = fanout!("alice", "1013-periodic") |> join_parent!()

    assert_receive {:periodic_reconcile_sent, body}, 2_000
    assert body == Fanout.format_report(Fanout.report(parent))

    assert eventually(fn -> Objectives.get_objective(parent.id) end).report_delivery_state ==
             "delivered"
  end

  test "completion work scans beyond a full corrupt prefix without starving valid delivery" do
    corrupt_ids =
      for index <- 1..100 do
        "notify-hol"
        |> fanout!("hol-corrupt-#{index}")
        |> join_parent!()
        |> Map.fetch!(:id)
      end

    valid = fanout!("notify-hol", "hol-valid") |> join_parent!()

    assert {100, _rows} =
             Objective
             |> where([objective], objective.id in ^corrupt_ids)
             |> Repo.update_all(set: [report_body: "corrupt selected report body"])

    assert Enum.map(Notify.pending_completion_work(1), & &1.id) == [valid.id]
  end

  test "consumer acknowledges durable delivery when its audit append fails" do
    parent = fanout!("alice", "1013-audit") |> join_parent!()
    enable_notify!("alice-ext")
    test_pid = self()

    consumer =
      start_ready_consumer(
        name: nil,
        retry_delay_ms: 25,
        notify_opts: [
          outbound_fun: fn _, _, _, _ ->
            send(test_pid, {:audit_failure_transport, parent.id})
            {:ok, %{message_id: "audit-failure-provider"}}
          end,
          audit_fun: fn :channel_notify, :delivered, _metadata, _decision ->
            {:error, :injected_audit_failure}
          end
        ]
      )

    Sandbox.allow(Repo, self(), consumer)
    send(consumer, :reconcile_completion_outbox)

    assert_receive {:audit_failure_transport, parent_id}, 2_000
    assert parent_id == parent.id

    assert eventually(fn -> Objectives.get_objective(parent.id) end).report_delivery_state ==
             "delivered"

    assert Repo.get_by!(NotifyDelivery, fanout_id: parent.id, kind: "completion").state ==
             "delivered"

    send(consumer, :reconcile_completion_outbox)
    refute_receive {:audit_failure_transport, _parent_id}, 200
  end

  test "consumer reauthorizes before retry and stops when notification consent is revoked" do
    parent = fanout!("alice", "1014") |> join_parent!()
    enable_notify!("alice-ext")
    attempts = :atomics.new(1, signed: false)
    test_pid = self()

    consumer =
      start_ready_consumer(
        name: nil,
        retry_delay_ms: 50,
        notify_opts: [
          outbound_fun: fn _, _, _, _ ->
            attempt = :atomics.add_get(attempts, 1, 1)
            send(test_pid, {:retry_attempt, attempt, self()})

            receive do
              :return_definitive_failure -> {:error, :connection_refused}
            after
              1_000 -> {:error, :test_timeout}
            end
          end
        ]
      )

    Sandbox.allow(Repo, self(), consumer)
    send(consumer, :reconcile_completion_outbox)

    assert_receive {:retry_attempt, 1, transport_pid}, 2_000
    put!("channels.telegram.autonomous_notify.enabled", false)
    send(transport_pid, :return_definitive_failure)
    refute_receive {:retry_attempt, 2, _pid}, 250
    assert :atomics.get(attempts, 1) == 1

    assert {:ok, pending} = Objectives.get_objective(parent.id)
    assert pending.report_delivery_state == "pending"

    delivery = eventually_delivery(parent.id, "suppressed")
    assert delivery.state == "suppressed"
    assert delivery.error_class =~ "notify_disabled"
  end

  test "a duplicate completion claimant cannot start a second transport" do
    parent = fanout!("alice", "1015") |> join_parent!()
    enable_notify!("alice-ext")
    test_pid = self()
    delivery_key = Notify.completion_delivery_key(parent)

    first =
      Task.async(fn ->
        deliver_ready(parent, :completion, "done",
          delivery_key: delivery_key,
          outbound_fun: fn _, _, _, _ ->
            send(test_pid, {:claim_transport_started, self()})

            receive do
              :finish_claim_transport -> {:ok, %{message_id: "claim-provider"}}
            end
          end
        )
      end)

    Sandbox.allow(Repo, self(), first.pid)
    assert_receive {:claim_transport_started, transport_pid}, 2_000

    second =
      Task.async(fn ->
        deliver_ready(parent, :completion, "duplicate",
          delivery_key: delivery_key,
          outbound_fun: fn _, _, _, _ -> flunk("second claimant must not reach transport") end
        )
      end)

    Sandbox.allow(Repo, self(), second.pid)
    assert {:ok, %{state: "sending"}} = Task.await(second, 2_000)
    send(transport_pid, :finish_claim_transport)
    assert {:ok, %{state: "delivered"}} = Task.await(first, 2_000)
  end

  test "SignalBus-only restart re-subscribes and replays pending completion work" do
    enable_notify!("alice-ext")
    test_pid = self()
    bus = :"notify-recovery-bus-#{System.unique_integer([:positive])}"
    bus_child = {:notify_recovery_bus, bus}

    _bus_pid = start_supervised!({Bus, name: bus}, id: bus_child)

    consumer =
      start_ready_consumer(
        name: nil,
        bus: bus,
        retry_delay_ms: 25,
        notify_opts: [
          outbound_fun: fn _, _, _, _ ->
            send(test_pid, :bus_restart_replay_sent)
            {:ok, %{message_id: "bus-restart-provider"}}
          end
        ]
      )

    Sandbox.allow(Repo, self(), consumer)
    assert :ok = stop_supervised(bus_child)

    parent = fanout!("alice", "1016") |> join_parent!()
    _restarted_bus = start_supervised!({Bus, name: bus}, id: bus_child)

    assert_receive :bus_restart_replay_sent, 2_000
    refute_receive :bus_restart_replay_sent, 150

    assert eventually(fn -> Objectives.get_objective(parent.id) end).report_delivery_state ==
             "delivered"
  end

  test "a forged joined signal cannot deliver a corrupted pending parent" do
    enable_notify!("alice-ext")
    parent = fanout!("alice", "1017")

    # Simulate corrupted historical state: the outbox marker exists while its
    # children are still active. Production transition authority cannot create it.
    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 status: "completed",
                 join_outcome: "success",
                 report_delivery_state: "pending",
                 completed_at: DateTime.utc_now()
               ]
             )

    test_pid = self()

    consumer =
      start_ready_consumer(
        name: nil,
        notify_opts: [
          outbound_fun: fn _, _, _, _ ->
            send(test_pid, :forged_completion_sent)
            {:ok, %{message_id: "must-not-send"}}
          end
        ]
      )

    Sandbox.allow(Repo, self(), consumer)
    assert :ok = Signals.emit_fanout(:fanout_joined, %{parent_id: parent.id})

    refute_receive :forged_completion_sent, 200

    refute Repo.exists?(
             from delivery in NotifyDelivery,
               where: delivery.fanout_id == ^parent.id and delivery.kind == "completion"
           )

    assert {:ok, :not_joined} =
             recover_completion_ready(parent,
               outbound_fun: fn _, _, _, _ -> flunk("corrupted report must not send") end
             )
  end

  defp fanout!(user_id, chat_id) do
    origin = notify_origin!(user_id, chat_id)

    {:ok, %{parent: parent}} =
      origin
      |> Map.merge(%{title: "Notify fan-out", objective: "Do two things"})
      |> Map.merge(ReadyEffectContext.context())
      |> Fanout.frame(["One", "Two"])

    parent
  end

  defp deliver_ready(parent, kind, body, opts) do
    Notify.deliver(
      parent,
      kind,
      body,
      Keyword.put_new(opts, :allbert_pack_epoch, ready_epoch())
    )
  end

  defp recover_completion_ready(parent, opts) do
    Notify.recover_completion(
      parent,
      Keyword.put_new(opts, :allbert_pack_epoch, ready_epoch())
    )
  end

  defp prepare_consent_offer_ready(parent) do
    Notify.prepare_consent_offer(parent, %{allbert_pack_epoch: ready_epoch()})
  end

  defp ready_epoch do
    ReadyEffectContext.context().allbert_pack_epoch
  end

  defp start_ready_consumer(opts) do
    context = ReadyEffectContext.context()
    effect_guard = {ReadyEpochGuard, ReadyEffectContext.server(context)}
    start_supervised!({NotifyConsumer, Keyword.put_new(opts, :effect_guard, effect_guard)})
  end

  defp selected_notify_report!(source, chat_id) do
    origin = notify_origin!("alice", chat_id)
    FanoutReportFixture.selected_report!(source, origin)
  end

  defp notify_origin!(user_id, chat_id) do
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

    digest = ChannelThread.canonical_ref_digest(ref)

    %{
      user_id: user_id,
      source_thread_id: thread.id,
      source_channel: "telegram",
      source_surface: "channel",
      origin_thread_ref_id: to_string(ref.id),
      origin_thread_ref_digest: digest,
      origin_receiver_account_ref: ref.receiver_account_ref
    }
  end

  defp join_parent!(parent) do
    %{parent: joined} =
      FanoutReportFixture.complete_and_select!(
        %{parent: parent, children: Fanout.children(parent)},
        :fallback
      )

    assert joined.report_delivery_state == "pending"
    joined
  end

  defp insert_completion_delivery!(parent, state, attempts, provider_message_id \\ nil) do
    %NotifyDelivery{}
    |> NotifyDelivery.changeset(%{
      delivery_key: Notify.completion_delivery_key(parent),
      fanout_id: parent.id,
      local_user_id: parent.user_id,
      channel: parent.source_channel,
      origin_thread_ref_id: parent.origin_thread_ref_id,
      origin_thread_ref_digest: parent.origin_thread_ref_digest,
      kind: "completion",
      state: state,
      attempt_count: attempts,
      provider_message_id: provider_message_id,
      offer_state: "not_applicable"
    })
    |> Repo.insert!()
  end

  defp enable_notify!(external_user_id) do
    put!("channels.telegram.identity_map", [identity(external_user_id, "alice")])
    put!("channels.telegram.autonomous_notify.enabled", true)
  end

  defp identity(external_user_id, user_id),
    do: %{"external_user_id" => external_user_id, "user_id" => user_id, "enabled" => true}

  defp put!(key, value) do
    assert {:ok, _setting} =
             Settings.put(
               key,
               value,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )
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

  defp eventually_true(fun, attempts \\ 40)
  defp eventually_true(fun, 0), do: fun.()

  defp eventually_true(fun, attempts) do
    if fun.() do
      true
    else
      Process.sleep(25)
      eventually_true(fun, attempts - 1)
    end
  end

  defp eventually_delivery(parent_id, state, attempts \\ 40)

  defp eventually_delivery(parent_id, state, 0) do
    delivery = Repo.get_by!(NotifyDelivery, fanout_id: parent_id, kind: "completion")
    assert delivery.state == state
    delivery
  end

  defp eventually_delivery(parent_id, state, attempts) do
    case Repo.get_by(NotifyDelivery, fanout_id: parent_id, kind: "completion") do
      %NotifyDelivery{state: ^state} = delivery ->
        delivery

      _other ->
        Process.sleep(25)
        eventually_delivery(parent_id, state, attempts - 1)
    end
  end
end
