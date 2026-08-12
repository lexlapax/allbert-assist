defmodule AllbertAssist.Channels.TUITest do
  use AllbertAssist.DataCase, async: false

  import Ecto.Query

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Event
  alias AllbertTUI.Adapter
  alias AllbertTUI.EscapeMonitor
  alias AllbertTUI.IdentityBootstrap
  alias AllbertTUI.InputDriver
  alias AllbertTUI.Renderer
  alias AllbertTUI.SlashCommands
  alias AllbertAssist.Coding.TurnSupervisor
  alias AllbertAssist.Confirmations
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias AllbertAssist.Conversations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.ReportComposer
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertTUI.Plugin, as: TUIPlugin
  alias AllbertAssist.Repo
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.DeliveryAcknowledgement
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Fragments
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.Trace
  alias Jido.Signal
  alias Jido.Signal.Bus

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.delete_env(:allbert_assist, Trace)

    unless match?({:ok, _}, PluginRegistry.lookup("allbert.tui")) do
      assert {:ok, "allbert.tui"} = PluginRegistry.register_module(TUIPlugin)
    end

    Fragments.clear_cache()

    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, request})

        {:ok,
         %{
           model_payload: "Clean TUI response: #{request.text}",
           surface_payload: "[surface] #{request.text}",
           status: :completed
         }}
      end
    )

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Runtime, original_runtime_config)
      restore_env(Settings, original_settings_config)
      restore_env(Trace, original_trace_config)
      Fragments.clear_cache()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "plugin descriptor declares local terminal channel contract" do
    assert [descriptor] = TUIPlugin.channels()

    assert descriptor.channel_id == "tui"
    assert descriptor.provider == "terminal"
    assert descriptor.primitives == [:typed_command, :list]
    assert descriptor.threading == :rich
    assert descriptor.trust_class == :local
    assert descriptor.settings_prefix == "channels.tui"
    assert descriptor.identity_map_key == "channels.tui.identity_map"
    assert descriptor.session_strategy == {:tui_session, prefix: "ch_tui_"}

    assert {:ok, descriptor} = Channels.channel_descriptor("tui")
    assert descriptor.trust_class == :local
  end

  test "adapter routes terminal input through runtime and emits surface payload" do
    configure_tui!()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:processed, event, ["[surface] hello tui"]}} =
             Adapter.submit(server, " hello tui ", external_event_id: "evt-tui-1")

    assert event.channel == "tui"
    assert event.provider == "terminal"
    assert event.status == "processed"

    assert_receive {:runtime_request, request}
    assert request.channel == "tui"
    assert request.text == "hello tui"
    assert request.user_id == "alice"
    assert String.starts_with?(request.session_id, "ch_tui_")
    assert request.channel_thread_ref.channel == "tui"
    assert request.channel_thread_ref.trust_class == "local"
    assert request.metadata.provider == "terminal"
    assert request.metadata.inbound_trust.permission == :channel_message_inbound

    assert_receive {:tui_output, "[surface] hello tui"}

    stored_event = Repo.get_by!(Event, channel: "tui", external_event_id: "evt-tui-1")
    assert stored_event.status == "processed"
    assert stored_event.user_id == "alice"
    assert stored_event.session_id == request.session_id
    assert stored_event.thread_id == request.thread_id
    assert is_binary(stored_event.input_signal_id)

    assert {:ok, %{messages: messages}} = Conversations.show_thread("alice", request.thread_id)

    # v1.0.2 M2 drift-fix (v055 eval precedent): the runtime can attach the
    # turn to a reused general thread carrying rows from earlier suites/runs,
    # so assert on THIS turn's user/assistant tail, not absolute positions.
    assert [
             %{role: "user", content: "hello tui"},
             %{role: "assistant", content: assistant_content}
           ] = Enum.take(messages, -2)

    assert assistant_content == "Clean TUI response: hello tui"
    refute assistant_content =~ "[surface]"
  end

  test "daemon callback publishes the durable bounded confirmation handoff only when required" do
    configure_tui!()
    parent = self()
    confirmation_id = "conf_tui_daemon_handoff"
    assert {:ok, confirmation} = create_confirmation!(confirmation_id, "tui")

    assert {:ok, expires_at, _offset} =
             confirmation["expires_at"]
             |> DateTime.from_iso8601()

    oversized_target = String.duplicate("é", 8_000)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})

        case request.text do
          "needs confirmation" ->
            {:ok,
             %{
               model_payload: "Confirmation is required.",
               surface_payload: "Confirmation is required.",
               status: :needs_confirmation,
               approval_handoff: %{
                 confirmation_id: confirmation_id,
                 status: :pending,
                 target_action: %{action: %{name: oversized_target}},
                 allowed_actions: [:approve, :deny]
               }
             }}

          text ->
            {:ok,
             %{
               model_payload: "ordinary response: #{text}",
               surface_payload: "ordinary response: #{text}",
               status: :completed
             }}
        end
      end
    )

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end,
               confirmation_fun: fn handoff ->
                 send(parent, {:daemon_confirmation_handoff, handoff})
                 :ok
               end
             )

    assert {:ok, {:processed, _event, [_rendered]}} =
             Adapter.submit(server, "needs confirmation",
               external_event_id: "evt-tui-daemon-handoff"
             )

    assert_receive {:daemon_confirmation_handoff,
                    %{
                      confirmation_id: ^confirmation_id,
                      prompt: prompt,
                      expires_at_unix_ms: expires_at_unix_ms
                    }}

    assert prompt != ""
    assert String.valid?(prompt)
    assert byte_size(prompt) <= 12 * 1_024
    assert prompt =~ "Approval: #{confirmation_id}"
    assert expires_at_unix_ms == DateTime.to_unix(expires_at, :millisecond)

    assert {:ok, durable_confirmation} = Confirmations.read(confirmation_id)
    assert durable_confirmation["expires_at"] == confirmation["expires_at"]

    assert {:ok, {:processed, _event, ["ordinary response: ordinary turn"]}} =
             Adapter.submit(server, "ordinary turn", external_event_id: "evt-tui-daemon-ordinary")

    refute_receive {:daemon_confirmation_handoff, _handoff}, 100
  end

  test "trusted local launcher bootstrap admits normal and slash turns as canonical local" do
    assert {:ok, %{disposition: :bootstrapped}} = IdentityBootstrap.prepare_local_launch()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:processed, _event, ["[surface] first local turn"]}} =
             Adapter.submit(server, "first local turn", external_event_id: "evt-tui-bootstrap")

    assert_receive {:runtime_request, %{user_id: "local", channel: "tui"}}

    assert {:ok, {:slash, [setting]}} =
             Adapter.submit(server, "/settings get channels.tui.identity_map",
               external_event_id: "evt-tui-bootstrap-setting"
             )

    assert setting =~ "default"
    assert setting =~ "local"
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-bootstrap-setting")
  end

  test "inbound admission failure is definitive, bounded, and leaves the TUI usable" do
    configure_tui!()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, :rejected} =
             Adapter.submit(server, "must roll back",
               external_event_id: "evt-tui-admission-failed",
               external_message_id: String.duplicate("x", 161)
             )

    assert_receive {:tui_output,
                    "Allbert could not save that request. Nothing was started; retry it."}

    event =
      Repo.get_by!(Event,
        channel: "tui",
        external_event_id: "evt-tui-admission-failed"
      )

    assert event.status == "failed"
    assert event.reason == "inbound_admission_failed"
    refute event.reason =~ "Exqlite"
    refute event.reason =~ "conversation_message_refs"
    assert Process.alive?(server)

    assert {:ok, {:processed, _event, ["[surface] next turn"]}} =
             Adapter.submit(server, "next turn",
               external_event_id: "evt-tui-after-admission-failed"
             )

    assert_receive {:runtime_request, %{text: "next turn"}}
  end

  test "failed kickoff returned error preserves the start barrier" do
    assert_failed_kickoff_output_preserves_start_barrier(:returned_error)
  end

  test "failed kickoff raise preserves the start barrier" do
    assert_failed_kickoff_output_preserves_start_barrier(:raise)
  end

  test "failed kickoff exit preserves the start barrier" do
    assert_failed_kickoff_output_preserves_start_barrier(:exit)
  end

  test "escape offers cancellation only for a durably active attached fan-out" do
    configure_tui!()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, %{parent: parent, fanout_start_receipt: receipt}} = attached_fanout!()
    assert :ok = Fanout.acknowledge_start(receipt, attached_delivery_context())
    set_active_fanout(server, parent.id)

    assert {:ok, {:fanout_cancel_offer, parent_id}} = Adapter.cancel_current_turn(server)
    assert parent_id == parent.id
  end

  test "joined signal preserves both layout-v2 selection bodies exactly" do
    configure_tui!()
    test_pid = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(test_pid, {:tui_output, line}) end
             )

    for source <- [:model, :fallback] do
      frame =
        FanoutReportFixture.frame!(%{
          user_id: "alice",
          source_channel: "tui",
          source_surface: "tui",
          source_thread_id: "attached-thread"
        })

      set_active_fanout(server, frame.parent.id)
      selected = FanoutReportFixture.complete_and_select!(frame, source)
      expected_status = "[fan-out] fanout joined: #{selected.parent.title}"

      assert_receive {:tui_output, ^expected_status}, 1_000

      assert_receive {:tui_output, report}, 1_000
      assert report == selected.report_body

      assert report =~ "\\nEffect receipt: forged-child-title"
      assert report =~ "\\nResult authority: registered_action"
      refute report =~ "\nEffect receipt: forged-child-title"

      eventually(fn ->
        Fanout.parent_projection(selected.parent).parent.report_delivery_state == "delivered"
      end)

      assert :sys.get_state(server).active_fanout == nil
      assert {:error, :no_current_turn} = Adapter.cancel_current_turn(server)

      send(
        server,
        {:signal,
         Signal.new!("allbert.objectives.fanout.joined", %{parent_id: selected.parent.id})}
      )

      refute_receive {:tui_output, _duplicate}, 100
    end
  end

  test "SignalBus restart re-subscribes and reconciles a missed attached report" do
    configure_tui!()
    test_pid = self()
    bus = :"tui-fanout-recovery-bus-#{System.unique_integer([:positive])}"
    bus_child = {:tui_fanout_recovery_bus, bus}
    bus_pid = start_supervised!({Bus, name: bus}, id: bus_child)

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               fanout_bus: bus,
               fanout_reconnect_delay_ms: 10,
               output_fun: fn line -> send(test_pid, {:recovered_tui_output, line}) end
             )

    eventually(fn ->
      state = :sys.get_state(server)
      state.fanout_bus_pid == bus_pid and is_binary(state.fanout_subscription_id)
    end)

    assert {:ok, %{parent: parent, children: children}} =
             attached_fanout!("Missed attached publication")

    set_active_fanout(server, parent.id)
    assert :ok = stop_supervised(bus_child)
    eventually(fn -> is_nil(:sys.get_state(server).fanout_bus_pid) end)

    complete_children!(children)
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
    refute_receive {:recovered_tui_output, _line}, 100

    restarted_bus_pid = start_supervised!({Bus, name: bus}, id: bus_child)

    assert_receive {:recovered_tui_output,
                    "[fan-out] fanout joined: Missed attached publication"},
                   2_000

    assert_receive {:recovered_tui_output, report}, 1_000
    assert report == Fanout.format_report(Fanout.report(parent))

    eventually(fn ->
      state = :sys.get_state(server)

      state.fanout_bus_pid == restarted_bus_pid and
        Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
    end)

    send(
      server,
      {:signal, Signal.new!("allbert.objectives.fanout.joined", %{parent_id: parent.id})}
    )

    refute_receive {:recovered_tui_output, _duplicate}, 100
  end

  test "a newly tracked attachment reconciles only after kickoff acknowledgement" do
    configure_tui!()
    test_pid = self()
    bus = :"tui-post-ack-recovery-bus-#{System.unique_integer([:positive])}"
    _bus_pid = start_supervised!({Bus, name: bus})

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               fanout_bus: bus,
               output_fun: fn line -> send(test_pid, {:post_ack_tui_output, line}) end
             )

    assert {:ok, %{parent: parent, children: children}} =
             attached_fanout!("Post-ack reconciliation")

    complete_children!(children)

    :sys.replace_state(server, fn state ->
      %{state | attended_turn: %{turn_id: "post-ack-turn"}}
    end)

    assert :ok =
             GenServer.call(
               server,
               {:attended_turn_handoff, "post-ack-turn",
                %{
                  fanout: %{parent_id: parent.id},
                  thread_id: parent.source_thread_id,
                  session_id: parent.session_id
                }}
             )

    refute_receive {:post_ack_tui_output, _line}, 100

    send(server, {:tui_fanout_kickoff_acknowledged, parent.id})

    assert_receive {:post_ack_tui_output, "[fan-out] fanout joined: Post-ack reconciliation"},
                   1_000

    assert_receive {:post_ack_tui_output, report}, 1_000
    assert report == Fanout.format_report(Fanout.report(parent))

    eventually(fn ->
      Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
    end)
  end

  test "daemon delivery custody waits for cumulative acknowledgement without blocking ordinary output" do
    configure_tui!()
    test_pid = self()

    delivery_output_fun = fn line ->
      send(test_pid, {:daemon_delivery_waiting, line, self()})

      receive do
        {:cumulative_ack, ^line} -> :ok
      end
    end

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(test_pid, {:daemon_queue_admitted, line}) end,
               delivery_output_fun: delivery_output_fun
             )

    assert {:ok, {:processed, _event, [ordinary]}} =
             Adapter.submit(server, "ordinary output",
               external_event_id: "evt-tui-daemon-ordinary-output"
             )

    assert_receive {:daemon_queue_admitted, ^ordinary}
    refute_receive {:daemon_delivery_waiting, ^ordinary, _worker}, 50

    assert {:ok, %{parent: parent, children: children}} =
             attached_fanout!("Daemon delivery custody")

    set_active_fanout(server, parent.id)
    complete_children!(children)

    assert_receive {:daemon_delivery_waiting, joined, delivery_worker}, 1_000
    assert joined == "[fan-out] fanout joined: Daemon delivery custody"
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
    refute_receive {:daemon_queue_admitted, ^joined}, 50

    send(delivery_worker, {:cumulative_ack, joined})

    assert_receive {:daemon_delivery_waiting, report, ^delivery_worker}, 1_000
    assert report =~ "title=\"Daemon delivery custody\" — success"
    assert Fanout.parent_projection(parent).parent.report_delivery_state == "pending"
    refute_receive {:daemon_queue_admitted, ^report}, 50

    send(delivery_worker, {:cumulative_ack, report})

    eventually(fn ->
      Fanout.parent_projection(parent).parent.report_delivery_state == "delivered"
    end)
  end

  test "transient report acknowledgement cannot restart the raw TUI or interrupt its attended FIFO" do
    configure_tui!()
    assert {:ok, _setting} = put_setting("objectives.fanout.enabled", false, %{audit?: false})
    parent = self()
    attempts = :counters.new(1, [:atomics])

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:overlap_runtime_started, request.text, self()})

        if request.text == "held independent turn" do
          receive do
            :release_overlap_turn -> :ok
          end
        end

        {:ok,
         %{
           model_payload: "overlap response: #{request.text}",
           surface_payload: "overlap response: #{request.text}",
           status: :completed
         }}
      end
    )

    acknowledge_fun = fn receipt, context ->
      DeliveryAcknowledgement.run(fn ->
        :counters.add(attempts, 1, 1)
        attempt = :counters.get(attempts, 1)
        send(parent, {:report_ack_attempt, attempt})

        if attempt == 1 do
          raise %DBConnection.ConnectionError{message: "injected acknowledgement contention"}
        else
          Runtime.acknowledge_report_delivery(receipt, context)
        end
      end)
    end

    {server, reader} =
      start_raw_tui!(parent, report_acknowledge_fun: acknowledge_fun)

    server_monitor = Process.monitor(server)
    assert {:ok, %{parent: fanout_parent, children: children}} = attached_fanout!("Overlap")
    set_active_fanout(server, fanout_parent.id)

    send_input_driver_line(reader, "held independent turn")
    assert_receive {:overlap_runtime_started, "held independent turn", held_worker}, 1_000
    assert_receive {:input_driver_output, "allbert:default> "}, 200

    complete_children!(children)

    joined_output = receive_input_driver_output_containing("[fan-out] fanout joined: Overlap")
    assert joined_output =~ "[fan-out] fanout joined: Overlap"
    report_output = receive_input_driver_output_containing("title=\"Overlap\" — success")
    assert report_output =~ "title=\"Overlap\" — success"
    assert_receive {:report_ack_attempt, 1}, 1_000

    send_input_driver_line(reader, "queued independent turn")
    assert_receive {:input_driver_output, "allbert:default> "}, 200
    refute_receive {:overlap_runtime_started, "queued independent turn", _worker}, 100
    refute_receive {:DOWN, ^server_monitor, :process, ^server, _reason}, 100

    send(held_worker, :release_overlap_turn)
    assert_receive {:overlap_runtime_started, "queued independent turn", _worker}, 1_000
    assert_receive {:report_ack_attempt, 2}, 1_000

    eventually(fn ->
      Process.alive?(server) and
        Fanout.parent_projection(fanout_parent).parent.report_delivery_state == "delivered" and
        :sys.get_state(server).attended_turn == nil
    end)

    drain_input_driver_output()

    send(
      server,
      {:signal, Signal.new!("allbert.objectives.fanout.joined", %{parent_id: fanout_parent.id})}
    )

    refute Enum.any?(
             collect_input_driver_output(100),
             &String.contains?(&1, "[fan-out] fanout joined: Overlap")
           )
  end

  test "exhausted or crashing report acknowledgement warns once and preserves pending truth" do
    configure_tui!()
    test_pid = self()

    failures = [
      exhausted: fn _receipt, _context ->
        DeliveryAcknowledgement.run(
          fn ->
            {:error, %DBConnection.ConnectionError{message: "persistent contention"}}
          end,
          attempts: 2,
          delay_fun: fn _delay -> :ok end
        )
      end,
      programming_error: fn _receipt, _context -> raise "injected acknowledgement bug" end
    ]

    Enum.each(failures, fn {label, acknowledge_fun} ->
      assert {:ok, server} =
               Adapter.start_link(
                 name: nil,
                 auto_input?: false,
                 enabled?: true,
                 live_screen?: false,
                 output_fun: fn line -> send(test_pid, {:failed_ack_output, label, line}) end,
                 report_acknowledge_fun: acknowledge_fun
               )

      server_monitor = Process.monitor(server)

      assert {:ok, %{parent: fanout_parent, children: children}} =
               attached_fanout!("Failed ACK #{label}")

      set_active_fanout(server, fanout_parent.id)
      complete_children!(children)

      assert_receive {:failed_ack_output, ^label, "[fan-out] fanout joined: " <> _title}, 1_000
      assert_receive {:failed_ack_output, ^label, report}, 1_000
      assert report =~ "title=\"Failed ACK #{label}\" — success"

      assert_receive {
                       :failed_ack_output,
                       ^label,
                       "[fan-out] report delivery could not be recorded; it remains available on your next turn."
                     },
                     1_000

      eventually(fn ->
        state = :sys.get_state(server)

        Process.alive?(server) and state.active_fanout == nil and
          MapSet.member?(state.displayed_unacknowledged_reports, fanout_parent.id) and
          Fanout.parent_projection(fanout_parent).parent.report_delivery_state == "pending"
      end)

      refute_receive {:DOWN, ^server_monitor, :process, ^server, _reason}, 100
      refute_receive {:failed_ack_output, ^label, _second_warning}, 100

      send(
        server,
        {:signal, Signal.new!("allbert.objectives.fanout.joined", %{parent_id: fanout_parent.id})}
      )

      refute_receive {:failed_ack_output, ^label, _duplicate}, 100
      GenServer.stop(server)
    end)
  end

  test "a written report acknowledgement can finish after the TUI adapter exits" do
    configure_tui!()
    test_pid = self()

    acknowledge_fun = fn receipt, context ->
      send(test_pid, {:detached_ack_worker, self()})

      receive do
        :finish_detached_ack -> Runtime.acknowledge_report_delivery(receipt, context)
      end
    end

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(test_pid, {:detached_ack_output, line}) end,
               report_acknowledge_fun: acknowledge_fun
             )

    assert {:ok, %{parent: fanout_parent, children: children}} =
             attached_fanout!("Detached ACK")

    set_active_fanout(server, fanout_parent.id)
    complete_children!(children)

    assert_receive {:detached_ack_output, "[fan-out] fanout joined: Detached ACK"}, 1_000
    assert_receive {:detached_ack_output, report}, 1_000
    assert report =~ "title=\"Detached ACK\" — success"
    assert_receive {:detached_ack_worker, worker}, 1_000

    assert :ok = GenServer.stop(server, :normal)
    assert Process.alive?(worker)
    assert Fanout.parent_projection(fanout_parent).parent.report_delivery_state == "pending"

    send(worker, :finish_detached_ack)

    eventually(fn ->
      Fanout.parent_projection(fanout_parent).parent.report_delivery_state == "delivered"
    end)
  end

  test "two attached fan-outs each deliver exactly once regardless of completion order" do
    configure_tui!()

    for order <- [:first_then_second, :second_then_first] do
      test_pid = self()

      assert {:ok, server} =
               Adapter.start_link(
                 name: nil,
                 auto_input?: false,
                 enabled?: true,
                 live_screen?: false,
                 output_fun: fn line -> send(test_pid, {:multi_tui_output, order, line}) end
               )

      assert {:ok, first} = attached_fanout!("Attached fan-out A #{order}")
      assert {:ok, second} = attached_fanout!("Attached fan-out B #{order}")
      set_active_fanout(server, first.parent.id)
      set_active_fanout(server, second.parent.id)

      sequence =
        if order == :first_then_second,
          do: [first, second],
          else: [second, first]

      Enum.each(sequence, fn frame ->
        complete_children!(frame.children)

        assert_receive {:multi_tui_output, ^order, "[fan-out] fanout joined: " <> joined_title},
                       1_000

        assert joined_title == frame.parent.title
        expected_title = "title=\"#{frame.parent.title}\" — success"
        report = receive_output_containing(order, expected_title)
        assert report =~ expected_title

        eventually(fn ->
          Fanout.parent_projection(frame.parent).parent.report_delivery_state == "delivered"
        end)
      end)

      state = :sys.get_state(server)
      assert state.active_fanout == nil
      assert state.attached_fanouts == %{}
      drain_multi_tui_output(order)

      Enum.each(sequence, fn frame ->
        send(
          server,
          {:signal,
           Signal.new!("allbert.objectives.fanout.joined", %{parent_id: frame.parent.id})}
        )
      end)

      refute_receive {:multi_tui_output, ^order, _duplicate}, 100
      GenServer.stop(server)
    end
  end

  test "failed attached output preserves the pending next-turn report" do
    configure_tui!()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> {:error, :closed_terminal} end
             )

    assert {:ok, %{parent: parent, children: children}} = attached_fanout!()
    set_active_fanout(server, parent.id)
    complete_children!(children)

    eventually(fn ->
      projection = Fanout.parent_projection(parent)
      projection.phase == :joined and projection.parent.report_delivery_state == "pending"
    end)

    eventually(fn -> :sys.get_state(server).active_fanout == nil end)
  end

  test "raised or exited attached output cannot crash the adapter or consume the report" do
    configure_tui!()

    for {label, output_fun} <- [
          {:raise, fn _line -> raise "terminal closed" end},
          {:exit, fn _line -> exit(:terminal_closed) end}
        ] do
      assert {:ok, server} =
               Adapter.start_link(
                 name: nil,
                 auto_input?: false,
                 enabled?: true,
                 live_screen?: false,
                 output_fun: output_fun
               )

      assert {:ok, %{parent: parent, children: children}} = attached_fanout!()
      set_active_fanout(server, parent.id)
      complete_children!(children)

      eventually(fn ->
        projection = Fanout.parent_projection(parent)

        Process.alive?(server) and projection.phase == :joined and
          projection.parent.report_delivery_state == "pending"
      end)

      assert :sys.get_state(server).active_fanout == nil, inspect(label)
      GenServer.stop(server)
    end
  end

  test "escape reports finalizing and wakes the durable owner for each recovery phase" do
    configure_tui!()

    assert {:ok,
            %{
              parent: composing_parent,
              children: composing_children,
              fanout_start_receipt: composing_receipt
            }} = attached_fanout!("Interrupted report composition")

    assert :ok = Fanout.acknowledge_start(composing_receipt, attached_delivery_context())
    terminalize_children!(composing_children)

    assert {:ok, %{parent: claimed_composing_parent}} =
             Fanout.claim_next_composition(allbert_pack_epoch: ReadyEffectContext.epoch())

    assert claimed_composing_parent.id == composing_parent.id

    assert {:ok,
            %{
              parent: queued_parent,
              children: queued_children,
              fanout_start_receipt: queued_receipt
            }} = attached_fanout!("Queued report composition")

    assert :ok = Fanout.acknowledge_start(queued_receipt, attached_delivery_context())
    terminalize_children!(queued_children)

    assert {:ok,
            %{
              parent: orphan_parent,
              children: orphan_children,
              fanout_start_receipt: orphan_receipt
            }} = attached_fanout!("Orphaned execution reduction")

    assert :ok = Fanout.acknowledge_start(orphan_receipt, attached_delivery_context())

    Enum.each(orphan_children, fn child ->
      observation = "orphaned result #{child.queue_position}"

      assert {:ok, step} =
               Objectives.create_step(
                 %{
                   objective_id: child.id,
                   kind: "action",
                   status: "completed",
                   stage: "observe_step",
                   candidate_action: "append_memory",
                   result_summary: observation
                 },
                 ReadyEffectContext.context()
               )

      assert {:ok, _event} =
               Objectives.create_event(
                 %{
                   objective_id: child.id,
                   kind: "run_completed",
                   payload: %{
                     summary: observation,
                     step_id: step.id,
                     step_status: "completed"
                   }
                 },
                 ReadyEffectContext.context()
               )

      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   current_step_id: step.id,
                   last_observation_summary: observation,
                   completed_at: DateTime.utc_now()
                 ]
               )
    end)

    assert %{phase: :recovering, parent: %{report_composition_state: "composing"}} =
             Fanout.parent_projection(composing_parent)

    assert %{phase: :recovering, parent: %{report_composition_state: "queued"}} =
             Fanout.parent_projection(queued_parent)

    assert %{phase: :recovering, parent: %{report_composition_state: "not_ready"}} =
             Fanout.parent_projection(orphan_parent)

    enable_default_report_composer!()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    for parent <- [queued_parent, claimed_composing_parent, orphan_parent] do
      set_active_fanout(server, parent.id)
      assert {:ok, {:fanout_finalizing, parent_id}} = Adapter.cancel_current_turn(server)
      assert parent_id == parent.id
      refute match?({:ok, {:fanout_cancel_offer, _}}, Adapter.cancel_current_turn(server))

      eventually(fn -> Fanout.parent_projection(parent).phase == :joined end)

      projection = Fanout.parent_projection(parent)
      assert projection.parent.report_composition_state == "fallback"
      assert projection.parent.report_delivery_state in ["pending", "delivered"]
      assert is_binary(projection.parent.report_body)
    end

    composing_selection = report_selection_payload(claimed_composing_parent.id)
    assert composing_selection["fallback_reason"] == "recovery_after_restart"

    orphan_join = objective_event_payload(orphan_parent.id, "fanout_joined")
    assert orphan_join["recovered"] == true
  end

  test "non-interactive supervised child stays quiet without launcher opts" do
    configure_tui!()
    parent = self()

    assert {:ok, _server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    refute_receive {:tui_output, _line}, 50
  end

  test "adapter treats repeated terminal event ids as duplicates" do
    configure_tui!()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, {:processed, _event, _rendered}} =
             Adapter.submit(server, "hello tui", external_event_id: "evt-tui-dupe")

    assert_receive {:runtime_request, _request}

    assert {:ok, :duplicate} =
             Adapter.submit(server, "hello again", external_event_id: "evt-tui-dupe")

    refute_received {:runtime_request, _request}
  end

  test "daemon-admitted input reuses its receipt event and reports actual completion" do
    configure_tui!()
    parent = self()
    receipt_id = "q83JzWf5JkzQ2WcB6mP8Ng"

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:daemon_runtime_started, request, self()})

        receive do
          :release_daemon_runtime -> :ok
        end

        {:ok,
         %{
           model_payload: "daemon response: #{request.text}",
           surface_payload: "daemon response: #{request.text}",
           status: :completed
         }}
      end
    )

    assert {:ok, event} =
             Channels.create_event(
               %{
                 channel: "tui",
                 provider: "terminal",
                 direction: "inbound",
                 external_event_id: "tui:r1:daemon-admitted",
                 external_user_id: "default",
                 external_chat_id: "tui:default",
                 external_message_id: receipt_id,
                 status: "received",
                 payload_summary: "tui receipt #{receipt_id}"
               },
               ReadyEffectContext.context()
             )

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:daemon_tui_output, line}) end,
               input_lifecycle_fun: fn input_receipt_id, admitted_event, phase ->
                 send(
                   parent,
                   {:daemon_input_lifecycle, input_receipt_id, admitted_event.id, phase}
                 )
               end
             )

    assert {:ok, {:accepted, ^receipt_id}} =
             Adapter.submit_admitted(server, " daemon request ", event, receipt_id)

    assert_receive {:daemon_input_lifecycle, ^receipt_id, event_id, :in_progress}, 1_000
    assert event_id == event.id

    assert_receive {:daemon_runtime_started, %{text: "daemon request"}, worker}, 1_000
    refute_receive {:daemon_input_lifecycle, ^receipt_id, ^event_id, {:terminal, _reply}}, 50

    assert Repo.aggregate(
             from(channel_event in Event,
               where:
                 channel_event.channel == "tui" and
                   channel_event.external_event_id == "tui:r1:daemon-admitted"
             ),
             :count
           ) == 1

    send(worker, :release_daemon_runtime)

    assert_receive {:daemon_input_lifecycle, ^receipt_id, ^event_id,
                    {:terminal, {:ok, {:processed, processed_event, [rendered]}}}},
                   1_000

    assert processed_event.id == event.id
    assert rendered == "daemon response: daemon request"
    assert_receive {:daemon_tui_output, ^rendered}
  end

  test "daemon-admitted slash, Pi turn, and correction keep receipt lifecycles on the attended queue" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-daemon-pi-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)
    configure_pi_tui!(repo)
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:daemon_pi_runtime_started, request.text, self()})

        receive do
          :release_daemon_pi_runtime -> :ok
        end

        {:ok,
         %{
           model_payload: "daemon Pi model: #{request.text}",
           surface_payload: "daemon Pi output: #{request.text}",
           status: :completed
         }}
      end
    )

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:daemon_pi_output, line}) end,
               input_lifecycle_fun: fn input_receipt_id, _event, phase ->
                 send(parent, {:daemon_pi_lifecycle, input_receipt_id, phase})
               end
             )

    slash_receipt = "AAAAAAAAAAAAAAAAAAAAAA"
    slash_event = create_admitted_tui_event!(slash_receipt, "daemon-pi-slash")

    assert {:ok, {:accepted, ^slash_receipt}} =
             Adapter.submit_admitted(server, "/pi #{repo}", slash_event, slash_receipt)

    assert_receive {:daemon_pi_lifecycle, ^slash_receipt, :in_progress}, 1_000

    assert_receive {:daemon_pi_lifecycle, ^slash_receipt,
                    {:terminal, {:ok, {:slash, [_entered]}}}},
                   1_000

    first_receipt = "BBBBBBBBBBBBBBBBBBBBBB"
    first_event = create_admitted_tui_event!(first_receipt, "daemon-pi-first")

    assert {:ok, {:accepted, ^first_receipt}} =
             Adapter.submit_admitted(server, "first daemon Pi turn", first_event, first_receipt)

    assert_receive {:daemon_pi_lifecycle, ^first_receipt, :in_progress}, 1_000
    assert_receive {:daemon_pi_runtime_started, "first daemon Pi turn", first_worker}, 1_000

    refute_receive {:daemon_pi_lifecycle, ^first_receipt, {:terminal, _reply}}, 50

    correction_receipt = "CCCCCCCCCCCCCCCCCCCCCC"
    correction_event = create_admitted_tui_event!(correction_receipt, "daemon-pi-correction")

    assert {:ok, {:accepted, ^correction_receipt}} =
             Adapter.submit_admitted(
               server,
               "correct the daemon Pi turn",
               correction_event,
               correction_receipt
             )

    refute_receive {:daemon_pi_runtime_started, "correct the daemon Pi turn", _worker}, 50
    refute_receive {:daemon_pi_lifecycle, ^correction_receipt, {:terminal, _reply}}, 50

    queued_receipt = "DDDDDDDDDDDDDDDDDDDDDD"
    queued_event = create_admitted_tui_event!(queued_receipt, "daemon-pi-queued")

    assert {:ok, {:accepted, ^queued_receipt}} =
             Adapter.submit_admitted(
               server,
               "queued after the correction",
               queued_event,
               queued_receipt
             )

    refute_receive {:daemon_pi_lifecycle, ^queued_receipt, :in_progress}, 50
    refute_receive {:daemon_pi_runtime_started, "queued after the correction", _worker}, 50

    send(first_worker, :release_daemon_pi_runtime)

    assert_receive {:daemon_pi_lifecycle, ^first_receipt,
                    {:terminal, {:ok, {:processed, _event, [_rendered]}}}},
                   1_000

    assert_receive {:daemon_pi_lifecycle, ^correction_receipt, :in_progress}, 1_000

    assert_receive {:daemon_pi_runtime_started, "correct the daemon Pi turn", correction_worker},
                   1_000

    refute_receive {:daemon_pi_lifecycle, ^correction_receipt, {:terminal, _reply}}, 50
    send(correction_worker, :release_daemon_pi_runtime)

    assert_receive {:daemon_pi_lifecycle, ^correction_receipt,
                    {:terminal, {:ok, {:processed, _event, [_rendered]}}}},
                   1_000

    assert_receive {:daemon_pi_lifecycle, ^queued_receipt, :in_progress}, 1_000

    assert_receive {:daemon_pi_runtime_started, "queued after the correction", queued_worker},
                   1_000

    refute_receive {:daemon_pi_lifecycle, ^queued_receipt, {:terminal, _reply}}, 50
    send(queued_worker, :release_daemon_pi_runtime)

    assert_receive {:daemon_pi_lifecycle, ^queued_receipt,
                    {:terminal, {:ok, {:processed, _event, [_rendered]}}}},
                   1_000
  end

  test "slash help renders canonical commands without runtime submission or channel event" do
    configure_tui!()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    # v0.62 M6: help renders every canonical command (the list grew with the
    # ADR 0070 read set), asserted against the source of truth rather than a
    # brittle inline snapshot.
    assert {:ok, {:slash, [rendered_help]}} =
             Adapter.submit(server, "/help", external_event_id: "evt-tui-slash-help")

    assert rendered_help =~ "Available slash commands:"

    for command <- SlashCommands.canonical_commands() do
      assert rendered_help =~ "- " <> command, "help missing #{command}"
    end

    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, rendered}
    assert rendered =~ "/status"
    assert rendered =~ "/intents"
    assert rendered =~ "/models"
    assert rendered =~ "/jobs"
    assert rendered =~ "/health"
    assert rendered =~ "/settings get"
    assert rendered =~ "/pi"
    assert rendered =~ "/mode"
    assert rendered =~ "/compact"
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-help")
  end

  test "unknown slash command is inert and does not echo arguments" do
    configure_tui!()
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:slash, [rendered]}} =
             Adapter.submit(server, "/bogus token=secret",
               external_event_id: "evt-tui-slash-unknown"
             )

    assert rendered == "Unknown slash command. Type /help for available commands."
    refute rendered =~ "secret"
    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, ^rendered}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-unknown")
  end

  test "operator slash data commands run internal read-only actions without runtime or channel events" do
    configure_tui!()
    assert {:ok, confirmation} = create_confirmation!("conf_tui_operator_console", "tui")
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:processed, _event, _rendered}} =
             Adapter.submit(server, "seed event", external_event_id: "evt-tui-inspection-seed")

    assert_receive {:runtime_request, %{text: "seed event"}}
    assert_receive {:tui_output, "[surface] seed event"}

    assert {:ok, {:slash, [status]}} =
             Adapter.submit(server, "/status", external_event_id: "evt-tui-slash-status")

    assert status =~ "Operator status:"
    assert status =~ "beam_os_pid:"
    assert status =~ "operator_id: alice"
    assert status =~ "Channels.Supervisor:"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-status")

    assert {:ok, {:slash, [channels]}} =
             Adapter.submit(server, "/channels", external_event_id: "evt-tui-slash-channels")

    assert channels =~ "Channels ("
    assert channels =~ "tui: provider=terminal enabled=true identities=1"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-channels")

    assert {:ok, {:slash, [confirmations]}} =
             Adapter.submit(server, "/confirmations",
               external_event_id: "evt-tui-slash-confirmations"
             )

    assert confirmations =~ confirmation["id"]
    assert confirmations =~ "status=pending"
    assert confirmations =~ "target=external_network_request"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-confirmations")

    assert {:ok, {:slash, [events]}} =
             Adapter.submit(server, "/events", external_event_id: "evt-tui-slash-events")

    assert events =~ "Recent channel events"
    assert events =~ "evt-tui-inspection-seed"
    refute events =~ "evt-tui-slash-events"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-events")

    assert {:ok, {:slash, [setting]}} =
             Adapter.submit(server, "/settings get channels.tui.identity_map",
               external_event_id: "evt-tui-slash-setting"
             )

    assert setting =~ "Setting channels.tui.identity_map:"
    assert setting =~ "alice"
    refute setting =~ "secret"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-setting")

    assert {:ok, {:slash, [invalid_setting]}} =
             Adapter.submit(server, "/settings get token=secret",
               external_event_id: "evt-tui-slash-setting-missing"
             )

    assert invalid_setting == "Invalid setting key."
    refute invalid_setting =~ "secret"
    refute_received {:runtime_request, _request}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-setting-missing")
  end

  test "operator inspection actions are internal slash-only candidates" do
    agent_action_names = Enum.map(Registry.agent_modules(), & &1.name())

    for action_name <- [
          "operator_status",
          "operator_confirmations",
          "operator_events",
          "operator_channels",
          "operator_setting_get",
          "intent_coverage",
          "model_doctor"
        ] do
      assert {:ok, module} = Registry.resolve(action_name)
      capability = module.capability()

      assert capability.permission == :read_only
      assert capability.exposure == :internal
      assert capability.confirmation == :not_required
      refute action_name in agent_action_names
    end
  end

  test "operator slash commands require mapped TUI identity before runner dispatch" do
    assert {:ok, _setting} = put_setting("channels.tui.enabled", true, %{audit?: false})
    assert {:ok, _setting} = put_setting("channels.tui.identity_map", [], %{audit?: false})
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, {:slash, [rendered]}} =
             Adapter.submit(server, "/status", external_event_id: "evt-tui-slash-unmapped")

    assert rendered ==
             "Slash command unavailable: terminal profile is not mapped to an Allbert user."

    refute_received {:runtime_request, _request}
    assert_receive {:tui_output, ^rendered}
    refute Repo.get_by(Event, channel: "tui", external_event_id: "evt-tui-slash-unmapped")
  end

  test "adapter generated terminal event ids are stable across launcher restarts" do
    configure_tui!()

    assert {:ok, first_server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, {:processed, first_event, _rendered}} =
             Adapter.submit(first_server, "first generated id")

    assert_receive {:runtime_request, _request}
    GenServer.stop(first_server)

    assert {:ok, second_server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, {:processed, second_event, _rendered}} =
             Adapter.submit(second_server, "second generated id")

    assert_receive {:runtime_request, _request}

    assert first_event.external_event_id =~
             ~r/^tui-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    assert second_event.external_event_id =~
             ~r/^tui-[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/

    refute first_event.external_event_id == second_event.external_event_id
  end

  test "renderer emits typed commands and numbered approval options" do
    handoff = %{
      confirmation_id: "conf_tui_render",
      status: :pending,
      target_action: %{action: %{name: "write_note"}},
      allowed_actions: [:approve, :deny, :details]
    }

    assert {:ok, [rendered]} =
             Renderer.render_response(%{
               message: "model-only fallback",
               approval_handoff: handoff
             })

    assert rendered =~ "Approval: conf_tui_render status=pending target=write_note"
    assert rendered =~ "Type one exact command:"
    assert rendered =~ "ALLBERT:APPROVE:conf_tui_render"
    assert rendered =~ "Approval options:"
    assert rendered =~ "1. Approve - ALLBERT:APPROVE:conf_tui_render"
    assert rendered =~ "2. Deny - ALLBERT:DENY:conf_tui_render"
    refute rendered =~ "allbert:v1:"
    refute rendered =~ "http"
  end

  test "renderer keeps approval controls when a streamed turn needs confirmation" do
    handoff = %{
      confirmation_id: "conf_tui_stream",
      status: :pending,
      target_action: %{action: %{name: "write"}},
      allowed_actions: [:approve, :deny, :details]
    }

    complete_event = %{
      type: :turn_complete,
      turn_id: "turn-stream-confirm",
      sequence: 1,
      model_payload: "model text",
      surface_payload: "streamed confirmation summary",
      metadata: %{status: :needs_confirmation}
    }

    assert {:ok, [rendered]} =
             Renderer.render_response(%{
               turn_id: "turn-stream-confirm",
               stream_events: [complete_event],
               approval_handoff: handoff
             })

    assert rendered =~ "streamed confirmation summary"
    assert rendered =~ "Approval: conf_tui_stream status=pending target=write"
    assert rendered =~ "ALLBERT:APPROVE:conf_tui_stream"
    assert rendered =~ "Approval options:"
  end

  test "renderer status line does not duplicate the input prompt" do
    prompt_text = Renderer.prompt("default") |> Owl.Data.untag() |> IO.iodata_to_binary()
    status_text = Renderer.status("default", :ready) |> Owl.Data.untag() |> IO.iodata_to_binary()

    assert prompt_text == "allbert:default> "
    assert status_text == "tui(default) ready"
    refute status_text =~ "allbert:default>"
  end

  test "input driver emits line events and handles backspace without line-mode input" do
    parent = self()
    callbacks = input_driver_callbacks(parent)

    assert {:ok, driver} =
             InputDriver.start_link(parent,
               enable_raw: callbacks.enable_raw,
               disable_raw: callbacks.disable_raw,
               start_reader: callbacks.start_reader,
               output_fun: callbacks.output_fun
             )

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}

    InputDriver.prompt(driver, "allbert:proof> ")
    assert_receive {:input_driver_output, "allbert:proof> "}

    send(reader, {:send_char, "h"})
    send(reader, {:send_char, "i"})
    send(reader, {:send_char, <<127>>})
    send(reader, {:send_char, "!"})
    send(reader, {:send_char, "\n"})

    assert_receive {:input_driver_output, "h"}
    assert_receive {:input_driver_output, "i"}
    assert_receive {:input_driver_output, "\b \b"}
    assert_receive {:input_driver_output, "!"}
    assert_receive {:input_driver_output, "\r\n"}
    assert_receive {:tui_input_line, ^driver, "h!"}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver preserves steering typed before the next prompt is rendered" do
    parent = self()
    callbacks = input_driver_callbacks(parent)

    assert {:ok, driver} =
             InputDriver.start_link(parent,
               enable_raw: callbacks.enable_raw,
               disable_raw: callbacks.disable_raw,
               start_reader: callbacks.start_reader,
               output_fun: callbacks.output_fun
             )

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}

    InputDriver.prompt(driver, "allbert:default> ")
    assert_receive {:input_driver_output, "allbert:default> "}

    send_input_driver_line(reader, "first turn")
    assert_receive {:tui_input_line, ^driver, "first turn"}

    "change task 1"
    |> String.graphemes()
    |> Enum.each(fn char -> send(driver, {:tui_input_driver_char, reader, char}) end)

    InputDriver.prompt(driver, "allbert:default> ")
    assert_receive {:input_driver_output, "allbert:default> "}
    send(driver, {:tui_input_driver_char, reader, "\n"})

    assert_receive {:tui_input_line, ^driver, "change task 1"}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver redraws the exact prompt and steering buffer after lifecycle output" do
    parent = self()
    callbacks = input_driver_callbacks(parent)

    assert {:ok, driver} =
             InputDriver.start_link(parent,
               enable_raw: callbacks.enable_raw,
               disable_raw: callbacks.disable_raw,
               start_reader: callbacks.start_reader,
               output_fun: callbacks.output_fun
             )

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}

    InputDriver.prompt(driver, "allbert:default> ")
    assert_receive {:input_driver_output, "allbert:default> "}

    "change task 1"
    |> String.graphemes()
    |> Enum.each(fn char -> send(driver, {:tui_input_driver_char, reader, char}) end)

    assert :ok = InputDriver.write(driver, "[fan-out] run progress")

    assert_receive {
      :input_driver_output,
      "\r\e[2K[fan-out] run progress\r\nallbert:default> change task 1"
    }

    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:tui_input_line, ^driver, "change task 1"}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "live input driver redraws only its owned wrapped rows across resize" do
    parent = self()
    {driver, _reader} = start_input_driver!(parent, live_region?: true, terminal_columns: 4)

    assert :ok = InputDriver.update_live(driver, 4, ["12345", "6789"])
    assert_receive {:input_driver_output, first_render}
    assert first_render == "12345\r\n6789"

    assert :ok = InputDriver.update_live(driver, 10, ["ok"])

    assert_receive {:input_driver_output, first_clear}
    assert first_clear == "\r\e[2K\e[1A\r\e[2K\e[1A\r\e[2K"

    assert_receive {:input_driver_output, second_render}
    assert second_render == "ok"

    assert :ok = InputDriver.update_live(driver, 2, ["abcdef"])
    assert_receive {:input_driver_output, second_clear}
    assert second_clear == "\r\e[2K"
    assert_receive {:input_driver_output, third_render}
    assert third_render == "abcdef"

    assert :ok = InputDriver.update_live(driver, 2, [])

    assert_receive {:input_driver_output, third_clear}
    assert third_clear == "\r\e[2K\e[1A\r\e[2K\e[1A\r\e[2K"

    outputs =
      [first_render, first_clear, second_render, second_clear, third_render, third_clear]
      |> Enum.join()

    refute outputs =~ "\e[2J"
    refute outputs =~ "\e[H"

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "live input driver preserves the prompt buffer through live and static output" do
    parent = self()
    {driver, reader} = start_input_driver!(parent, live_region?: true, terminal_columns: 80)

    InputDriver.prompt(driver, "allbert:default> ")
    assert_receive {:input_driver_output, "allbert:default> "}

    Enum.each(String.graphemes("change task"), fn char ->
      send(driver, {:tui_input_driver_char, reader, char})
      assert_receive {:input_driver_output, ^char}
    end)

    assert :ok = InputDriver.update_live(driver, 80, ["working"])
    assert_receive {:input_driver_output, "\r\e[2K"}
    assert_receive {:input_driver_output, "working\r\nallbert:default> change task"}

    assert :ok = InputDriver.write(driver, "completed")
    assert_receive {:input_driver_output, "\r\e[2K\e[1A\r\e[2K"}
    assert_receive {:input_driver_output, "completed\r\n"}
    assert_receive {:input_driver_output, "working\r\nallbert:default> change task"}

    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:input_driver_output, "\r\e[2K\e[1A\r\e[2K"}
    assert_receive {:input_driver_output, "allbert:default> change task\r\n"}
    assert_receive {:tui_input_line, ^driver, "change task"}
    assert_receive {:input_driver_output, "working"}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "live input driver reports clear and redraw failures to synchronous callers" do
    parent = self()
    failure = start_supervised!({Agent, fn -> nil end})

    output_fun = fn chardata ->
      text = IO.iodata_to_binary(chardata)
      send(parent, {:input_driver_output, text})

      case Agent.get(failure, & &1) do
        {:return, ^text} -> {:error, :device_unavailable}
        {:raise, ^text} -> raise "injected terminal failure"
        {:exit, ^text} -> exit(:injected_terminal_failure)
        _other -> :ok
      end
    end

    {driver, _reader} =
      start_input_driver!(parent,
        live_region?: true,
        terminal_columns: 80,
        output_fun: output_fun
      )

    Agent.update(failure, fn _current -> {:return, "cannot redraw"} end)

    assert {:error, :device_unavailable} =
             InputDriver.update_live(driver, 80, ["cannot redraw"])

    assert Process.alive?(driver)

    Agent.update(failure, fn _current -> nil end)
    assert :ok = InputDriver.update_live(driver, 80, ["stable"])

    Agent.update(failure, fn _current -> {:return, "stable"} end)
    assert {:error, :device_unavailable} = InputDriver.write(driver, "completed")
    assert Process.alive?(driver)

    Agent.update(failure, fn _current -> {:raise, "raised redraw"} end)

    assert {:error, {:output_exception, "injected terminal failure"}} =
             InputDriver.update_live(driver, 80, ["raised redraw"])

    Agent.update(failure, fn _current -> {:exit, "exited redraw"} end)

    assert {:error, {:output_exit, :injected_terminal_failure}} =
             InputDriver.update_live(driver, 80, ["exited redraw"])

    assert Process.alive?(driver)
    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "single-submission input demand waits for the next client prompt" do
    parent = self()
    callbacks = input_driver_callbacks(parent)

    start_reader = fn driver, _read_char ->
      reader = spawn_link(fn -> single_submission_reader_loop(parent, driver) end)
      send(parent, {:input_driver_reader, reader})
      {:ok, reader}
    end

    assert {:ok, driver} =
             InputDriver.start_link(parent,
               enable_raw: callbacks.enable_raw,
               disable_raw: callbacks.disable_raw,
               start_reader: start_reader,
               output_fun: callbacks.output_fun,
               live_region?: true,
               single_submission?: true
             )

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}

    InputDriver.prompt(driver, "allbert> ")
    assert_receive {:input_driver_output, "allbert> "}

    Enum.each(String.graphemes("first\n"), fn char ->
      assert_receive {:single_submission_demand, ^reader, ^driver}
      send(reader, {:single_submission_char, char})
    end)

    assert_receive {:tui_input_line, ^driver, "first"}
    refute_receive {:single_submission_demand, ^reader, ^driver}, 50

    InputDriver.prompt(driver, "allbert> ")
    assert_receive {:input_driver_output, "allbert> "}
    assert_receive {:single_submission_demand, ^reader, ^driver}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver enforces its byte cap without accepting a partial character" do
    parent = self()
    {driver, reader} = start_input_driver!(parent, max_buffer_bytes: 4)

    InputDriver.prompt(driver, "allbert:cap> ")
    assert_receive {:input_driver_output, "allbert:cap> "}

    for char <- ["a", "é"] do
      send(driver, {:tui_input_driver_char, reader, char})
      assert_receive {:input_driver_output, ^char}
    end

    send(driver, {:tui_input_driver_char, reader, "é"})
    assert_receive {:input_driver_output, "\a"}

    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:input_driver_output, "\r\n"}
    assert_receive {:tui_input_line, ^driver, "aé"}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver rejects C1 controls instead of echoing or submitting them" do
    parent = self()
    c1_next_line = <<0xC2, 0x85>>
    {driver, reader} = start_input_driver!(parent)

    InputDriver.prompt(driver, "allbert:control> ")
    assert_receive {:input_driver_output, "allbert:control> "}

    send(driver, {:tui_input_driver_char, reader, c1_next_line})
    send(driver, {:tui_input_driver_char, reader, "x"})
    send(driver, {:tui_input_driver_char, reader, "\n"})

    assert_receive {:input_driver_output, "x"}
    assert_receive {:input_driver_output, "\r\n"}
    assert_receive {:tui_input_line, ^driver, "x"}
    refute_received {:input_driver_output, ^c1_next_line}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver preserves one in-flight character across pause and resume" do
    parent = self()
    {driver, reader} = start_input_driver!(parent)

    InputDriver.prompt(driver, "allbert:pressure> ")
    assert_receive {:input_driver_output, "allbert:pressure> "}

    assert :ok = InputDriver.pause(driver)
    send(driver, {:tui_input_driver_char, reader, "q"})
    assert :ok = InputDriver.pause(driver)
    refute_received {:input_driver_output, "q"}

    assert :ok = InputDriver.resume(driver)
    assert_receive {:input_driver_output, "q"}

    send(driver, {:tui_input_driver_char, reader, "\n"})
    assert_receive {:input_driver_output, "\r\n"}
    assert_receive {:tui_input_line, ^driver, "q"}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver clears its live region and emits quit on Ctrl-C" do
    parent = self()
    {driver, reader} = start_input_driver!(parent, live_region?: true)

    InputDriver.prompt(driver, "allbert:interrupt> ")
    assert_receive {:input_driver_output, "allbert:interrupt> "}

    assert :ok = InputDriver.update_live(driver, 80, ["working"])
    assert_receive {:input_driver_output, "\r\e[2K"}
    assert_receive {:input_driver_output, "working\r\nallbert:interrupt> "}

    send(driver, {:tui_input_driver_char, reader, <<3>>})
    assert_receive {:input_driver_output, "\r\e[2K\e[1A\r\e[2K"}
    assert_receive {:input_driver_output, "\r\n"}
    assert_receive {:tui_input_quit, ^driver, :ctrl_c}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver maps reader EOF to the same clear-and-quit restoration path" do
    parent = self()
    {driver, reader} = start_input_driver!(parent, live_region?: true)

    InputDriver.prompt(driver, "allbert:eof> ")
    assert_receive {:input_driver_output, "allbert:eof> "}

    assert :ok = InputDriver.update_live(driver, 80, ["waiting"])
    assert_receive {:input_driver_output, "\r\e[2K"}
    assert_receive {:input_driver_output, "waiting\r\nallbert:eof> "}

    send(reader, :send_eof)
    assert_receive {:input_driver_output, "\r\e[2K\e[1A\r\e[2K"}
    assert_receive {:input_driver_output, "\r\n"}
    assert_receive {:tui_input_quit, ^driver, :ctrl_d}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "auto input driver keeps adapter output in raw-terminal line discipline" do
    parent = self()
    {server, reader} = start_raw_tui!(parent)

    send_input_driver_line(reader, "/mode")
    assert_receive {:input_driver_output, "\r\n"}

    assert_receive {
      :input_driver_output,
      "\r\e[2KSlash command unavailable: terminal profile is not mapped to an Allbert user.\r\nallbert:default> "
    }

    ref = Process.monitor(server)
    send_input_driver_line(reader, "/quit")
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
    assert_receive {:input_driver_raw, :disabled}
  end

  test "auto input driver visibly rejects an unmapped ordinary turn and stays usable" do
    parent = self()
    {server, reader} = start_raw_tui!(parent)

    send_input_driver_line(reader, "hello from an unmapped terminal")
    assert_receive {:input_driver_output, "\r\n"}

    assert_receive {
      :input_driver_output,
      "\r\e[2KMessage not sent: terminal profile is not mapped to an Allbert user. Configure channels.tui.identity_map.\r\nallbert:default> "
    }

    refute_received {:runtime_request, _request}

    event =
      Repo.get_by!(Event,
        channel: "tui",
        external_user_id: "default",
        status: "rejected"
      )

    assert event.reason == ":not_mapped"

    ref = Process.monitor(server)
    send_input_driver_line(reader, "/quit")
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
    assert_receive {:input_driver_raw, :disabled}
  end

  test "auto input driver visibly rejects a disabled identity entry and stays usable" do
    assert {:ok, _setting} =
             put_setting(
               "channels.tui.identity_map",
               [
                 %{
                   "external_user_id" => "default",
                   "user_id" => "local",
                   "enabled" => false
                 }
               ],
               %{audit?: false}
             )

    parent = self()
    {server, reader} = start_raw_tui!(parent)

    send_input_driver_line(reader, "hello from a disabled terminal mapping")
    assert_receive {:input_driver_output, "\r\n"}

    assert_receive {
      :input_driver_output,
      "\r\e[2KMessage not sent: terminal profile mapping is disabled.\r\nallbert:default> "
    }

    refute_received {:runtime_request, _request}

    event =
      Repo.get_by!(Event,
        channel: "tui",
        external_user_id: "default",
        status: "rejected"
      )

    assert event.reason == ":disabled"

    ref = Process.monitor(server)
    send_input_driver_line(reader, "/quit")
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
    assert_receive {:input_driver_raw, :disabled}
  end

  test "raw TUI accepts lifecycle output and the next line while a Runtime turn is held" do
    configure_tui!()
    assert {:ok, _setting} = put_setting("objectives.fanout.enabled", false, %{audit?: false})

    parent = self()

    blocker =
      spawn(fn ->
        receive do
          {:hold, runner} ->
            send(parent, {:ordered_runtime_started, "first slow turn", runner})

            receive do
              :release -> send(runner, :release_attended_turn)
            end
        end
      end)

    on_exit(fn -> send(blocker, :release) end)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        case request.text do
          "first slow turn" ->
            send(blocker, {:hold, self()})

            receive do
              :release_attended_turn -> :ok
            end

          text ->
            send(parent, {:ordered_runtime_started, text, self()})

            receive do
              :release_attended_turn -> :ok
            end
        end

        {:ok,
         %{
           model_payload: "ordered response: #{request.text}",
           surface_payload: "ordered response: #{request.text}",
           status: :completed
         }}
      end
    )

    {server, reader} = start_raw_tui!(parent)

    assert {:ok, %{parent: fanout_parent}} = attached_fanout!("Held-turn lifecycle")

    progress_signal =
      Signal.new!("allbert.objectives.run.progress", %{
        parent_id: fanout_parent.id,
        child_id: "held-runtime-child",
        title: "held runtime"
      })

    send(server, {:signal, progress_signal})

    refute_receive {
                     :input_driver_output,
                     "\r\e[2K[fan-out] run progress: held runtime\r\nallbert:default> "
                   },
                   50

    set_active_fanout(server, fanout_parent.id)

    send_input_driver_line(reader, "first slow turn")
    assert_receive {:ordered_runtime_started, "first slow turn", first_runner}, 1_000
    first_monitor = Process.monitor(first_runner)
    assert_receive {:input_driver_output, "allbert:default> "}, 200

    "second "
    |> String.graphemes()
    |> Enum.each(fn char -> send(reader, {:send_char, char}) end)

    Enum.each(1..25, fn _index -> send(server, {:signal, progress_signal}) end)

    assert_receive {
                     :input_driver_output,
                     "\r\e[2K[fan-out] run progress: held runtime\r\nallbert:default> second "
                   },
                   200

    send_input_driver_line(reader, "turn")
    assert_receive {:input_driver_output, "allbert:default> "}, 200

    refute_receive {
                     :input_driver_output,
                     "\r\e[2K[fan-out] run progress: held runtime\r\nallbert:default> second "
                   },
                   100

    refute_receive {:ordered_runtime_started, "second turn", _runner}, 100

    send(blocker, :release)

    assert_receive {
                     :input_driver_output,
                     "\r\e[2Kordered response: first slow turn\r\nallbert:default> "
                   },
                   1_000

    assert_receive {:DOWN, ^first_monitor, :process, ^first_runner, :normal}, 1_000
    assert_receive {:ordered_runtime_started, "second turn", second_runner}, 1_000
    refute second_runner == first_runner
    second_monitor = Process.monitor(second_runner)
    send(second_runner, :release_attended_turn)

    assert_receive {
                     :input_driver_output,
                     "\r\e[2Kordered response: second turn\r\nallbert:default> "
                   },
                   1_000

    assert_receive {:DOWN, ^second_monitor, :process, ^second_runner, :normal}, 1_000
    eventually(fn -> :sys.get_state(server).attended_turn == nil end)
  end

  test "raw TUI shows the first progress line again after a durable retry attempt starts" do
    configure_tui!()
    parent = self()
    {server, reader} = start_raw_tui!(parent)

    assert {:ok, %{parent: fanout_parent}} = attached_fanout!("Retry progress")
    set_active_fanout(server, fanout_parent.id)

    signal_data = %{
      parent_id: fanout_parent.id,
      child_id: "retried-child",
      title: "retried child"
    }

    progress_signal = Signal.new!("allbert.objectives.run.progress", signal_data)
    send(server, {:signal, progress_signal})

    assert_receive {:input_driver_output, first_progress}, 500
    assert first_progress =~ "[fan-out] run progress: retried child"

    send(server, {:signal, progress_signal})
    refute_receive {:input_driver_output, _duplicate_progress}, 100

    started_signal =
      Signal.new!("allbert.objectives.run.started", Map.put(signal_data, :attempt, 2))

    send(server, {:signal, started_signal})
    assert_receive {:input_driver_output, second_start}, 500
    assert second_start =~ "[fan-out] run started: retried child"

    send(server, {:signal, progress_signal})
    assert_receive {:input_driver_output, second_progress}, 500
    assert second_progress =~ "[fan-out] run progress: retried child"

    ref = Process.monitor(server)
    send_input_driver_line(reader, "/quit")
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
    assert_receive {:input_driver_raw, :disabled}
  end

  test "raw TUI hands its fanout attachment back before kickoff acknowledgement" do
    configure_tui!()

    assert {:ok, _setting} =
             put_setting("objectives.fanout.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             put_setting("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             put_setting("objectives.fanout.confirm_before_start", true, %{audit?: false})

    configure_fanout_roles!()

    parent = self()

    {server, reader} = start_raw_tui!(parent)

    send_input_driver_line(
      reader,
      "Do these two tasks in parallel: first handoff task; second handoff task"
    )

    assert_receive {:input_driver_output, "\r\n"}
    assert_receive {:input_driver_output, "allbert:default> "}

    eventually(fn ->
      Repo.exists?(
        from objective in Objective,
          where: objective.user_id == "alice" and objective.fanout_role == "parent"
      )
    end)

    fanout_parent =
      Repo.one!(
        from objective in Objective,
          where: objective.user_id == "alice" and objective.fanout_role == "parent",
          order_by: [desc: objective.inserted_at],
          limit: 1
      )

    eventually(fn ->
      state = :sys.get_state(server)

      state.active_fanout == %{
        parent_id: fanout_parent.id,
        thread_id: fanout_parent.source_thread_id,
        session_id: fanout_parent.session_id
      }
    end)

    eventually(fn ->
      Fanout.parent_projection(fanout_parent).parent.kickoff_delivery_state == "acknowledged"
    end)

    assert Enum.all?(Fanout.children(fanout_parent), &(&1.run_attempt_count == 0))
    eventually(fn -> :sys.get_state(server).attended_turn == nil end)
  end

  test "raw TUI advances its attended FIFO when the active worker exits" do
    configure_tui!()
    assert {:ok, _setting} = put_setting("objectives.fanout.enabled", false, %{audit?: false})
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:crash_runtime_started, request.text, self()})

        if request.text == "worker to stop" do
          receive do
            :unexpected_release -> :ok
          end
        end

        {:ok,
         %{
           model_payload: "recovered response: #{request.text}",
           surface_payload: "recovered response: #{request.text}",
           status: :completed
         }}
      end
    )

    {server, reader} = start_raw_tui!(parent)

    send_input_driver_line(reader, "worker to stop")
    assert_receive {:crash_runtime_started, "worker to stop", worker}, 1_000
    worker_monitor = Process.monitor(worker)
    assert_receive {:input_driver_output, "allbert:default> "}, 200

    send_input_driver_line(reader, "queued after stop")
    assert_receive {:input_driver_output, "allbert:default> "}, 200
    refute_receive {:crash_runtime_started, "queued after stop", _worker}, 100

    Process.exit(worker, :kill)

    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :killed}, 1_000

    assert_receive {
                     :input_driver_output,
                     "\r\e[2KTUI request stopped before completion. Nothing new was started; retry the request.\r\nallbert:default> "
                   },
                   1_000

    assert_receive {:crash_runtime_started, "queued after stop", _worker}, 1_000

    assert_receive {
                     :input_driver_output,
                     "\r\e[2Krecovered response: queued after stop\r\nallbert:default> "
                   },
                   1_000

    eventually(fn -> :sys.get_state(server).attended_turn == nil end)
  end

  test "raw TUI bounds its attended FIFO and stops its active worker on shutdown" do
    configure_tui!()
    assert {:ok, _setting} = put_setting("objectives.fanout.enabled", false, %{audit?: false})
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:bounded_runtime_started, request.text, self()})

        receive do
          :unexpected_release -> :ok
        end

        {:ok,
         %{
           model_payload: "unexpected response",
           surface_payload: "unexpected response",
           status: :completed
         }}
      end
    )

    {server, reader} = start_raw_tui!(parent)

    send_input_driver_line(reader, "held for bounded queue")
    assert_receive {:bounded_runtime_started, "held for bounded queue", worker}, 1_000
    worker_monitor = Process.monitor(worker)

    Enum.each(1..33, fn index ->
      send_input_driver_line(reader, "queued turn #{index}")
    end)

    assert_receive {
                     :input_driver_output,
                     "\r\e[2KTUI input queue is full; wait for an earlier request to finish and retry.\r\nallbert:default> "
                   },
                   2_000

    eventually(fn -> :queue.len(:sys.get_state(server).attended_turn_queue) == 32 end)
    refute_receive {:bounded_runtime_started, "queued turn 1", _worker}, 100

    server_monitor = Process.monitor(server)
    GenServer.stop(server, :normal)

    assert_receive {:DOWN, ^server_monitor, :process, ^server, :normal}, 1_000
    assert_receive {:DOWN, ^worker_monitor, :process, ^worker, :shutdown}, 1_000
    assert_receive {:input_driver_raw, :disabled}, 1_000
  end

  test "input driver emits standalone escape without echoing terminal controls" do
    parent = self()
    callbacks = input_driver_callbacks(parent)

    assert {:ok, driver} =
             InputDriver.start_link(parent,
               enable_raw: callbacks.enable_raw,
               disable_raw: callbacks.disable_raw,
               start_reader: callbacks.start_reader,
               output_fun: callbacks.output_fun
             )

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}

    InputDriver.active_turn(driver, "turn-input-driver-escape")
    send(reader, {:send_char, "\e"})

    assert_receive {:tui_input_escape, ^driver}
    refute_received {:input_driver_output, "^["}

    GenServer.stop(driver)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "input driver proof harness emits CRLF proof lines" do
    parent = self()
    callbacks = input_driver_callbacks(parent)

    task =
      Task.async(fn ->
        InputDriver.run_proof(
          enable_raw: callbacks.enable_raw,
          disable_raw: callbacks.disable_raw,
          start_reader: callbacks.start_reader,
          output_fun: callbacks.output_fun,
          timeout_ms: 1_000
        )
      end)

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}
    assert_receive {:input_driver_output, "allbert:proof> "}

    send(reader, {:send_char, "\e"})

    assert_receive {:input_driver_output, "PROOF:ESC\r\n"}
    refute_received {:input_driver_output, "PROOF:ESC\n"}

    assert :ok = Task.await(task)
    assert_receive {:input_driver_raw, :disabled}
  end

  test "auto input driver cancels an async Pi-mode turn without escape monitor helper" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-pi-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)
    configure_pi_tui!(repo)
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        :ok =
          TurnSupervisor.register_stream_cancel(
            request.coding_turn_id,
            fn -> send(parent, {:stream_cancelled, request.coding_turn_id}) end
          )

        send(parent, {:runtime_request, request})

        receive do
          :release_runtime ->
            {:ok,
             %{
               model_payload: "model #{request.text}",
               surface_payload: "done #{request.text}",
               status: :completed
             }}
        after
          5_000 ->
            {:ok,
             %{
               model_payload: "model timeout",
               surface_payload: "done timeout",
               status: :completed
             }}
        end
      end
    )

    callbacks = input_driver_callbacks(parent)

    escape_monitor_fun = fn _owner, _event_ref ->
      send(parent, :escape_monitor_should_not_start)
      :ignore
    end

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: true,
               input_driver?: true,
               emit_banner?: false,
               enabled?: true,
               live_screen?: false,
               input_driver_opts: [
                 enable_raw: callbacks.enable_raw,
                 disable_raw: callbacks.disable_raw,
                 start_reader: callbacks.start_reader,
                 output_fun: callbacks.output_fun
               ],
               escape_monitor_fun: escape_monitor_fun,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}
    assert_receive {:input_driver_output, "allbert:default> "}

    send_input_driver_line(reader, "/pi #{repo}")
    assert_receive {:tui_output, "Pi-mode entered: " <> _entered}, 1_000
    assert_receive {:input_driver_output, "allbert:default> "}, 1_000

    send_input_driver_line(reader, "Read docs/plans/archives/v0.57-plan.md")
    assert_receive {:runtime_request, request}, 1_000
    assert request.text == "Read docs/plans/archives/v0.57-plan.md"
    assert Map.fetch!(request, :coding_turn?) == true
    refute_received :escape_monitor_should_not_start

    send(reader, {:send_char, "\e"})

    assert_receive {:stream_cancelled, turn_id}, 1_000
    assert turn_id == request.coding_turn_id
    assert_receive {:tui_output, "Cancellation requested for coding turn " <> _}, 1_000
    assert_receive {:tui_output, "Turn cancelled:" <> _}, 1_000
    assert_receive {:input_driver_output, "allbert:default> "}, 1_000
    refute_received {:input_driver_output, "^["}

    ref = Process.monitor(server)
    send_input_driver_line(reader, "/quit")
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
    assert_receive {:input_driver_raw, :disabled}
  end

  test "auto input waits for an async Pi-mode turn before opening the next prompt" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-pi-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)
    configure_pi_tui!(repo)
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        Kernel.send(parent, {:runtime_request, self(), request})

        receive do
          :release_runtime ->
            {:ok,
             %{
               model_payload: "model #{request.text}",
               surface_payload: "done #{request.text}",
               status: :completed
             }}
        after
          2_000 ->
            {:ok,
             %{
               model_payload: "model timeout",
               surface_payload: "done timeout",
               status: :completed
             }}
        end
      end
    )

    input_fun = fn prompt ->
      prompt_text = prompt |> Owl.Data.untag() |> IO.iodata_to_binary()
      send(parent, {:tui_prompt, prompt_text})

      receive do
        {:next_input, input} -> input
      after
        5_000 -> "/quit"
      end
    end

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: true,
               emit_banner?: false,
               enabled?: true,
               live_screen?: false,
               input_fun: input_fun,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert_receive {:tui_prompt, "allbert:default> "}
    send(server, {:next_input, "/pi #{repo}"})
    assert_receive {:tui_output, "Pi-mode entered: " <> _entered}, 1_000
    assert_receive {:tui_prompt, "allbert:default> "}, 1_000

    send(server, {:next_input, "Read docs/plans/archives/v0.57-plan.md"})
    assert_receive {:runtime_request, runner_pid, request}, 1_000
    assert Map.fetch!(request, :coding_turn?) == true
    assert request.text == "Read docs/plans/archives/v0.57-plan.md"

    refute_receive {:tui_prompt, "allbert:default> "}, 100
    refute_receive {:tui_output, "done Read docs/plans/archives/v0.57-plan.md"}, 100

    send(runner_pid, :release_runtime)
    assert_receive {:tui_output, "done Read docs/plans/archives/v0.57-plan.md"}, 1_000
    assert_receive {:tui_prompt, "allbert:default> "}, 1_000

    ref = Process.monitor(server)
    send(server, {:next_input, "/quit"})
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
  end

  test "auto input treats slash commands with leading terminal controls as local commands" do
    configure_tui!()
    parent = self()

    input_fun = fn prompt ->
      prompt_text = prompt |> Owl.Data.untag() |> IO.iodata_to_binary()
      send(parent, {:tui_prompt, prompt_text})

      receive do
        {:next_input, input} -> input
      after
        5_000 -> "/quit"
      end
    end

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: true,
               emit_banner?: false,
               enabled?: true,
               live_screen?: false,
               input_fun: input_fun,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert_receive {:tui_prompt, "allbert:default> "}

    ref = Process.monitor(server)
    send(server, {:next_input, "\e/exit"})

    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
    refute_received {:runtime_request, _request}
  end

  test "slash help includes both quit aliases" do
    configure_tui!()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:ok, {:slash, [rendered]}} =
             Adapter.submit(server, "/help", external_event_id: "evt-tui-help-quit-aliases")

    assert rendered =~ "/exit"
    assert rendered =~ "/quit"
  end

  test "auto input escape monitor cancels an async Pi-mode turn before the next prompt" do
    repo =
      Path.join(
        System.tmp_dir!(),
        "allbert-tui-pi-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(repo)
    File.mkdir_p!(repo)
    on_exit(fn -> File.rm_rf(repo) end)
    configure_pi_tui!(repo)
    parent = self()

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        :ok =
          TurnSupervisor.register_stream_cancel(
            request.coding_turn_id,
            fn -> send(parent, {:stream_cancelled, request.coding_turn_id}) end
          )

        send(parent, {:runtime_request, request})

        receive do
          :release_runtime ->
            {:ok,
             %{
               model_payload: "model #{request.text}",
               surface_payload: "done #{request.text}",
               status: :completed
             }}
        after
          5_000 ->
            {:ok,
             %{
               model_payload: "model timeout",
               surface_payload: "done timeout",
               status: :completed
             }}
        end
      end
    )

    input_fun = fn prompt ->
      prompt_text = prompt |> Owl.Data.untag() |> IO.iodata_to_binary()
      send(parent, {:tui_prompt, prompt_text})

      receive do
        {:next_input, input} -> input
      after
        5_000 -> "/quit"
      end
    end

    escape_monitor_fun = fn owner, event_ref ->
      monitor =
        spawn(fn ->
          send(parent, {:escape_monitor_started, self(), event_ref})

          receive do
            :send_escape ->
              send(owner, {:coding_tui_escape, event_ref})

            {:stop_escape_monitor, ^event_ref} ->
              :ok
          after
            5_000 ->
              :ok
          end
        end)

      {:ok, monitor}
    end

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: true,
               emit_banner?: false,
               enabled?: true,
               live_screen?: false,
               input_fun: input_fun,
               escape_monitor_fun: escape_monitor_fun,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert_receive {:tui_prompt, "allbert:default> "}
    send(server, {:next_input, "/pi #{repo}"})
    assert_receive {:tui_output, "Pi-mode entered: " <> _entered}, 1_000
    assert_receive {:tui_prompt, "allbert:default> "}, 1_000

    send(server, {:next_input, "Read docs/plans/archives/v0.57-plan.md"})
    assert_receive {:runtime_request, request}, 1_000
    assert request.text == "Read docs/plans/archives/v0.57-plan.md"
    assert Map.fetch!(request, :coding_turn?) == true
    assert_receive {:escape_monitor_started, monitor, _event_ref}, 1_000

    refute_receive {:tui_prompt, "allbert:default> "}, 100
    send(monitor, :send_escape)

    assert_receive {:stream_cancelled, turn_id}, 1_000
    assert turn_id == request.coding_turn_id
    assert_receive {:tui_output, "Cancellation requested for coding turn " <> _}, 1_000
    assert_receive {:tui_output, "Turn cancelled:" <> _}, 1_000
    assert_receive {:tui_prompt, "allbert:default> "}, 1_000

    ref = Process.monitor(server)
    send(server, {:next_input, "/quit"})
    assert_receive {:DOWN, ^ref, :process, ^server, :normal}
  end

  test "escape monitor maps helper escape output to coding escape event" do
    event_ref = make_ref()
    parent = self()
    helper_ref = make_ref()

    start_helper = fn ->
      monitor = self()
      send(parent, {:helper_started, monitor, helper_ref})
      send(monitor, {helper_ref, {:data, {:eol, "READY"}}})
      {:ok, %{port: helper_ref, os_pid: nil}}
    end

    stop_helper = fn helper ->
      send(parent, {:helper_stopped, helper})
      :ok
    end

    assert {:ok, monitor} =
             EscapeMonitor.start(self(), event_ref,
               start_helper: start_helper,
               stop_helper: stop_helper
             )

    assert_receive {:helper_started, ^monitor, ^helper_ref}
    send(monitor, {helper_ref, {:data, {:eol, "ESC"}}})
    assert_receive {:coding_tui_escape, ^event_ref}
    assert_receive {:helper_stopped, %{port: ^helper_ref, os_pid: nil}}
  end

  test "typed and daemon confirmation commands resolve without runtime submission" do
    configure_tui!()
    assert {:ok, confirmation} = create_confirmation!("conf_tui_typed", "tui")
    assert {:ok, daemon_confirmation} = create_confirmation!("conf_tui_daemon", "tui")
    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               emit_banner?: true,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert_receive {:tui_output, _banner}
    assert_receive {:tui_output, _banner}

    assert {:ok, {:processed, event, [rendered]}} =
             Adapter.submit(server, "ALLBERT:DENY:#{confirmation["id"]}",
               external_event_id: "evt-tui-callback"
             )

    refute_received {:runtime_request, %{text: "ALLBERT:DENY:" <> _rest}}
    assert_receive {:tui_output, output}

    assert event.direction == "callback"
    assert event.status == "processed"
    assert event.user_id == "alice"
    assert rendered =~ "denied"
    assert output =~ "denied"

    assert {:ok, resolved} = Confirmations.read(confirmation["id"])
    assert resolved["status"] == "denied"
    assert resolved["operator_resolution"]["resolver_actor"] == "alice"
    assert resolved["operator_resolution"]["resolver_channel"] == "tui"
    assert resolved["operator_resolution"]["resolver_metadata"]["command"] =~ "DENY"

    assert {:ok, {:confirmation, response, [daemon_rendered]}} =
             Adapter.confirm(server, daemon_confirmation["id"], :deny,
               external_event_id: "evt-tui-daemon-confirmation"
             )

    assert response.status == :completed
    assert daemon_rendered =~ "denied"
    assert_receive {:tui_output, ^daemon_rendered}
    refute_received {:runtime_request, _request}

    refute Repo.get_by(Event,
             channel: "tui",
             external_event_id: "evt-tui-daemon-confirmation"
           )

    assert {:ok, daemon_resolved} = Confirmations.read(daemon_confirmation["id"])
    assert daemon_resolved["status"] == "denied"
    assert daemon_resolved["operator_resolution"]["resolver_actor"] == "alice"
    assert daemon_resolved["operator_resolution"]["resolver_channel"] == "tui"
    assert daemon_resolved["operator_resolution"]["resolver_metadata"]["command"] =~ "DENY"
  end

  test "typed and daemon confirmation commands cannot resolve other-channel confirmations" do
    configure_tui!()
    assert {:ok, confirmation} = create_confirmation!("conf_tui_wrong_channel", "slack")

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn _line -> :ok end
             )

    assert {:error, :wrong_channel} =
             Adapter.confirm(server, confirmation["id"], :deny,
               external_event_id: "evt-tui-daemon-wrong-channel"
             )

    refute Repo.get_by(Event,
             channel: "tui",
             external_event_id: "evt-tui-daemon-wrong-channel"
           )

    assert {:ok, daemon_pending} = Confirmations.read(confirmation["id"])
    assert daemon_pending["status"] == "pending"

    assert {:ok, :rejected} =
             Adapter.submit(server, "ALLBERT:DENY:#{confirmation["id"]}",
               external_event_id: "evt-tui-wrong-channel"
             )

    refute_received {:runtime_request, _request}

    event = Repo.get_by!(Event, channel: "tui", external_event_id: "evt-tui-wrong-channel")
    assert event.direction == "callback"
    assert event.status == "rejected"
    assert event.reason == ":wrong_channel"

    assert {:ok, pending} = Confirmations.read(confirmation["id"])
    assert pending["status"] == "pending"
  end

  test "adapter rejects unmapped terminal identity without invoking runtime" do
    assert {:ok, _setting} = put_setting("channels.tui.enabled", true, %{audit?: false})
    assert {:ok, _setting} = put_setting("channels.tui.identity_map", [], %{audit?: false})

    parent = self()

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: fn line -> send(parent, {:tui_output, line}) end
             )

    assert {:ok, :rejected} =
             Adapter.submit(server, "hello tui", external_event_id: "evt-tui-reject")

    refute_received {:runtime_request, _request}

    assert_receive {:tui_output,
                    "Message not sent: terminal profile is not mapped to an Allbert user. Configure channels.tui.identity_map."}

    event = Repo.get_by!(Event, channel: "tui", external_event_id: "evt-tui-reject")
    assert event.status == "rejected"
    assert event.reason == ":not_mapped"
  end

  defp attached_fanout!(title \\ "Attached fan-out") do
    Fanout.frame(
      ReadyEffectContext.attach(%{
        user_id: "alice",
        source_channel: "tui",
        source_surface: "tui",
        source_thread_id: "attached-thread",
        title: title,
        objective: "Exercise attached completion"
      }),
      ["first", "second"]
    )
  end

  defp attached_delivery_context do
    ReadyEffectContext.attach(%{user_id: "alice", channel: "tui", thread_id: "attached-thread"})
  end

  defp set_active_fanout(server, parent_id) do
    attachment = %{
      parent_id: parent_id,
      thread_id: "attached-thread",
      session_id: nil
    }

    :sys.replace_state(
      server,
      fn state ->
        state
        |> Map.put(:active_fanout, attachment)
        |> Map.update!(:attached_fanouts, &Map.put(&1, parent_id, attachment))
      end
    )
  end

  defp complete_children!(children) do
    parent_id = children |> hd() |> Map.fetch!(:parent_objective_id)
    parent = Repo.get!(Objective, parent_id)
    :ok = FanoutReportFixture.complete_children!(children)
    FanoutReportFixture.select_completed!(%{parent: parent, children: children}, :fallback)
    :ok
  end

  defp terminalize_children!(children), do: FanoutReportFixture.complete_children!(children)

  defp enable_default_report_composer! do
    original_state = :sys.get_state(ReportComposer)

    on_exit(fn -> restore_report_composer_state(original_state) end)

    :sys.replace_state(ReportComposer, fn state ->
      %{
        state
        | enabled?: true,
          model_enabled?: false,
          phase: :ready,
          drain_requested?: false,
          reconcile_requested?: false,
          retry_attempts: %{recover: 0, claim: 0, select: 0}
      }
    end)
  end

  defp restore_report_composer_state(original_state) do
    if Process.whereis(ReportComposer) do
      :sys.replace_state(ReportComposer, fn state ->
        %{
          state
          | enabled?: original_state.enabled?,
            model_enabled?: original_state.model_enabled?,
            phase: original_state.phase,
            drain_requested?: original_state.drain_requested?,
            reconcile_requested?: original_state.reconcile_requested?,
            retry_attempts: original_state.retry_attempts
        }
      end)
    end
  end

  defp report_selection_payload(parent_id),
    do: objective_event_payload(parent_id, "fanout_report_selected")

  defp objective_event_payload(parent_id, kind) do
    parent_id
    |> AllbertAssist.Objectives.list_events()
    |> Enum.find(&(&1.kind == kind))
    |> Map.fetch!(:payload)
    |> Jason.decode!()
  end

  defp receive_output_containing(order, needle) do
    receive do
      {:multi_tui_output, ^order, line} ->
        if String.contains?(line, needle),
          do: line,
          else: receive_output_containing(order, needle)
    after
      1_000 -> flunk("TUI output did not contain #{inspect(needle)}")
    end
  end

  defp receive_input_driver_output_containing(needle) do
    receive do
      {:input_driver_output, line} ->
        if String.contains?(line, needle),
          do: line,
          else: receive_input_driver_output_containing(needle)
    after
      1_000 -> flunk("raw TUI output did not contain #{inspect(needle)}")
    end
  end

  defp drain_input_driver_output do
    receive do
      {:input_driver_output, _line} -> drain_input_driver_output()
    after
      0 -> :ok
    end
  end

  defp collect_input_driver_output(timeout_ms, output \\ []) do
    receive do
      {:input_driver_output, line} -> collect_input_driver_output(timeout_ms, [line | output])
    after
      timeout_ms -> Enum.reverse(output)
    end
  end

  defp drain_multi_tui_output(order) do
    receive do
      {:multi_tui_output, ^order, _line} -> drain_multi_tui_output(order)
    after
      0 -> :ok
    end
  end

  defp eventually(fun, attempts \\ 100)

  defp eventually(fun, attempts) when attempts > 0 do
    if fun.() do
      :ok
    else
      Process.sleep(10)
      eventually(fun, attempts - 1)
    end
  end

  defp eventually(_fun, 0), do: flunk("condition did not become true")

  defp assert_failed_kickoff_output_preserves_start_barrier(output_failure) do
    configure_tui!()

    configure_fanout_roles!()

    assert {:ok, _setting} =
             put_setting("objectives.fanout.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             put_setting("objectives.fanout.rollout_mode", "automatic", %{audit?: false})

    assert {:ok, _setting} =
             put_setting("objectives.fanout.confirm_before_start", false, %{audit?: false})

    output_fun =
      case output_failure do
        :returned_error -> fn _line -> {:error, :closed_terminal} end
        :raise -> fn _line -> raise "terminal closed" end
        :exit -> fn _line -> exit(:terminal_closed) end
      end

    assert {:ok, server} =
             Adapter.start_link(
               name: nil,
               auto_input?: false,
               enabled?: true,
               live_screen?: false,
               output_fun: output_fun
             )

    assert {:ok, :rejected} =
             Adapter.submit(
               server,
               "Do two things: first task and second task. Work on them in parallel.",
               external_event_id: "evt-failed-kickoff-#{output_failure}"
             )

    assert Process.alive?(server)

    parent =
      Repo.one!(
        from objective in Objective,
          where: objective.user_id == "alice" and objective.fanout_role == "parent",
          order_by: [desc: objective.inserted_at],
          limit: 1
      )

    refute parent.kickoff_delivery_state == "acknowledged"
    assert parent.kickoff_delivery_state == "blocked"

    Process.sleep(50)

    assert Fanout.children(parent)
           |> Enum.all?(&(&1.status == "open" and &1.run_attempt_count == 0))
  end

  # v1.3 M9.b.12.d. Runtime gates fan-out admission on model readiness
  # (`fanout_role_readiness_step/3`): with no callable profile the turn degrades
  # to a single answer and no parent is ever created. These rows predate that
  # gate and never stubbed it, so they asserted a start barrier on a fan-out that
  # could not exist. `fanout_ack_test` already uses this pattern.
  defp configure_fanout_roles! do
    original_readiness = Application.get_env(:allbert_assist, :runtime_model_readiness)

    Application.put_env(
      :allbert_assist,
      :runtime_model_readiness,
      AllbertAssist.Test.ModelReadinessFake
    )

    on_exit(fn ->
      if original_readiness,
        do: Application.put_env(:allbert_assist, :runtime_model_readiness, original_readiness),
        else: Application.delete_env(:allbert_assist, :runtime_model_readiness)
    end)

    assert {:ok, _} = put_setting("providers.openai.enabled", false, %{audit?: false})
    assert {:ok, _} = put_setting("intent.direct_answer_model_enabled", true, %{audit?: false})

    Enum.each(~w[direct_answer fanout_manager fanout_synthesis], fn role ->
      assert {:ok, _} =
               put_setting(
                 "model_preferences.tasks.#{role}",
                 ["direct_answer_local"],
                 %{audit?: false}
               )
    end)
  end

  defp configure_tui! do
    assert {:ok, _setting} = put_setting("channels.tui.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             put_setting(
               "channels.tui.identity_map",
               [
                 %{
                   "external_user_id" => "default",
                   "user_id" => "alice",
                   "enabled" => true
                 }
               ],
               %{audit?: false}
             )
  end

  defp configure_pi_tui!(repo) do
    configure_tui!()
    assert {:ok, _setting} = put_setting("coding.pi_mode.enabled", true, %{audit?: false})
    assert {:ok, _setting} = put_setting("coding.trusted_operator_id", "alice", %{audit?: false})

    assert {:ok, _setting} =
             put_setting("coding.default_approval_mode", "default", %{audit?: false})

    assert {:ok, _setting} = put_setting("coding.workspace.cwd_jail", repo, %{audit?: false})

    assert {:ok, _setting} =
             put_setting("coding.model_profile", "pi_coding_local", %{audit?: false})
  end

  defp create_admitted_tui_event!(receipt_id, suffix) do
    assert {:ok, event} =
             Channels.create_event(
               %{
                 channel: "tui",
                 provider: "terminal",
                 direction: "inbound",
                 external_event_id: "tui:r1:#{suffix}",
                 external_user_id: "default",
                 external_chat_id: "tui:default",
                 external_message_id: receipt_id,
                 status: "received",
                 payload_summary: "tui receipt #{receipt_id}"
               },
               ReadyEffectContext.context()
             )

    event
  end

  defp input_driver_callbacks(parent) do
    %{
      enable_raw: fn ->
        send(parent, {:input_driver_raw, :enabled})
        :ok
      end,
      disable_raw: fn ->
        send(parent, {:input_driver_raw, :disabled})
        :ok
      end,
      start_reader: fn driver, _read_char ->
        reader =
          spawn_link(fn ->
            send(parent, {:input_driver_reader, self()})
            input_driver_reader_loop(driver)
          end)

        {:ok, reader}
      end,
      output_fun: fn chardata ->
        send(parent, {:input_driver_output, IO.iodata_to_binary(chardata)})
      end
    }
  end

  defp start_input_driver!(parent, opts \\ []) do
    callbacks = input_driver_callbacks(parent)

    driver_opts =
      [
        enable_raw: callbacks.enable_raw,
        disable_raw: callbacks.disable_raw,
        start_reader: callbacks.start_reader,
        output_fun: callbacks.output_fun
      ]
      |> Keyword.merge(opts)

    assert {:ok, driver} = InputDriver.start_link(parent, driver_opts)
    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}
    {driver, reader}
  end

  defp start_raw_tui!(parent, opts \\ []) do
    callbacks = input_driver_callbacks(parent)

    adapter_opts =
      [
        name: nil,
        auto_input?: true,
        input_driver?: true,
        emit_banner?: false,
        enabled?: true,
        live_screen?: false,
        input_driver_opts: [
          enable_raw: callbacks.enable_raw,
          disable_raw: callbacks.disable_raw,
          start_reader: callbacks.start_reader,
          output_fun: callbacks.output_fun
        ]
      ]
      |> Keyword.merge(opts)

    assert {:ok, server} =
             Adapter.start_link(adapter_opts)

    assert_receive {:input_driver_raw, :enabled}
    assert_receive {:input_driver_reader, reader}
    assert_receive {:input_driver_output, "allbert:default> "}

    {server, reader}
  end

  defp input_driver_reader_loop(driver) do
    receive do
      {:send_char, char} ->
        send(driver, {:tui_input_driver_char, self(), char})
        input_driver_reader_loop(driver)

      :send_eof ->
        send(driver, {:tui_input_driver_reader_error, self(), :eof})

      :stop ->
        :ok
    end
  end

  defp single_submission_reader_loop(parent, driver) do
    receive do
      {:tui_input_driver_read, ^driver} ->
        send(parent, {:single_submission_demand, self(), driver})

        receive do
          {:single_submission_char, char} ->
            send(driver, {:tui_input_driver_char, self(), char})
            single_submission_reader_loop(parent, driver)

          {:tui_input_driver_stop, ^driver} ->
            :ok
        end

      {:tui_input_driver_stop, ^driver} ->
        :ok
    end
  end

  defp send_input_driver_line(reader, line) do
    line
    |> String.graphemes()
    |> Enum.each(fn char -> send(reader, {:send_char, char}) end)

    send(reader, {:send_char, "\n"})
  end

  defp create_confirmation!(id, channel) do
    Confirmations.create(
      %{
        id: id,
        origin: %{actor: "alice", channel: channel, surface: "tui-test"},
        target_action: %{name: "external_network_request"},
        target_permission: :external_network,
        target_execution_mode: :external_network_unavailable,
        security_decision: %{permission: :external_network, decision: :needs_confirmation},
        params_summary: %{url: "https://example.com"}
      },
      ReadyEffectContext.context()
    )
  end

  defp put_setting(key, value, context),
    do: Settings.put(key, value, ReadyEffectContext.attach(context))

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
