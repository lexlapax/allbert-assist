defmodule AllbertAssistWeb.SignalBridgeTest do
  use AllbertAssistWeb.ConnCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.Objectives
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.Guard
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias AllbertAssistWeb.SignalBridge
  alias Jido.Signal

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "signal-bridge-test-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Guard.reset_for_test()

    on_exit(fn ->
      Guard.reset_for_test()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

  test "subscribes to objective and workspace signal patterns" do
    parent = self()
    name = :"signal_bridge_patterns_#{System.unique_integer([:positive])}"

    start_supervised!(
      {SignalBridge,
       name: name,
       subscribe_fun: fn AllbertAssist.SignalBus, pattern ->
         send(parent, {:subscribed, pattern})
         {:ok, pattern}
       end,
       validate_fun: fn _epoch -> :ok end}
    )

    SignalBridge.open(name, epoch())
    assert_open(name)

    assert_receive {:subscribed, "allbert.objective.**"}
    assert_receive {:subscribed, "allbert.objectives.**"}
    assert_receive {:subscribed, "allbert.workspace.**"}
  end

  test "a partial subscription failure closes every subscription and refuses the bridge" do
    parent = self()
    name = :"signal_bridge_partial_#{System.unique_integer([:positive])}"

    start_supervised!(
      {SignalBridge,
       name: name,
       subscribe_fun: fn AllbertAssist.SignalBus, pattern ->
         if pattern == "allbert.workspace.**", do: {:error, :unavailable}, else: {:ok, pattern}
       end,
       unsubscribe_fun: fn AllbertAssist.SignalBus, subscription_id ->
         send(parent, {:unsubscribed, subscription_id})
         :ok
       end,
       validate_fun: fn _epoch -> :ok end}
    )

    assert {:error, :unavailable} = SignalBridge.open(name, epoch())
    assert_receive {:unsubscribed, "allbert.objective.**"}
    assert_receive {:unsubscribed, "allbert.objectives.**"}
    assert %{epoch: nil, subscription_ids: %{}} = :sys.get_state(name)
  end

  test "retires subscriptions before the epoch bridge terminates" do
    parent = self()
    name = :"signal_bridge_retire_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {SignalBridge,
         name: name,
         subscribe_fun: fn AllbertAssist.SignalBus, pattern -> {:ok, pattern} end,
         unsubscribe_fun: fn AllbertAssist.SignalBus, subscription_id ->
           send(parent, {:unsubscribed, subscription_id})
           :ok
         end,
         validate_fun: fn _epoch -> :ok end}
      )

    SignalBridge.open(name, epoch())
    assert_open(name)
    ref = Process.monitor(pid)

    SignalBridge.close(name)

    assert_receive {:unsubscribed, "allbert.objective.**"}
    assert_receive {:unsubscribed, "allbert.objectives.**"}
    assert_receive {:unsubscribed, "allbert.workspace.**"}
    assert_receive {:DOWN, ^ref, :process, ^pid, :normal}
  end

  test "queued E1 signals are suppressed during rotation and never replayed by the E2 bridge" do
    e1 = %{
      barrier_pid: spawn(fn -> Process.sleep(:infinity) end),
      snapshot_digest: String.duplicate("a", 64)
    }

    e2 = %{
      barrier_pid: spawn(fn -> Process.sleep(:infinity) end),
      snapshot_digest: String.duplicate("a", 64)
    }

    readiness = start_supervised!({Agent, fn -> e1 end})

    bridge_opts = fn name ->
      [
        name: name,
        subscribe_fun: fn _bus, pattern -> {:ok, pattern} end,
        unsubscribe_fun: fn _bus, _subscription_id -> :ok end,
        validate_fun: fn epoch ->
          if epoch == Agent.get(readiness, & &1), do: :ok, else: {:error, :stale_epoch}
        end
      ]
    end

    e1_name = :"signal_bridge_queued_e1_#{System.unique_integer([:positive])}"
    e1_pid = start_supervised!({SignalBridge, bridge_opts.(e1_name)})
    assert :ok = SignalBridge.open(e1_name, e1)

    Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, SignalBridge.topic_for("alice"))

    assert {:ok, stale_signal} =
             Signal.new(
               "allbert.objective.created",
               %{user_id: "alice", objective_id: nil, title: "stale E1"},
               source: "/allbert/test"
             )

    :erlang.suspend_process(e1_pid)
    Agent.update(readiness, fn _ -> e2 end)
    send(e1_pid, {:signal, stale_signal})
    SignalBridge.close(e1_pid)
    e1_ref = Process.monitor(e1_pid)
    :erlang.resume_process(e1_pid)

    assert_receive {:DOWN, ^e1_ref, :process, ^e1_pid, :normal}
    refute_receive {:objective_event, %{data: %{title: "stale E1"}}}, 100

    e2_name = :"signal_bridge_queued_e2_#{System.unique_integer([:positive])}"
    e2_pid = start_supervised!({SignalBridge, bridge_opts.(e2_name)})
    assert :ok = SignalBridge.open(e2_name, e2)

    assert {:ok, fresh_signal} =
             Signal.new(
               "allbert.objective.created",
               %{user_id: "alice", objective_id: nil, title: "fresh E2"},
               source: "/allbert/test"
             )

    send(e2_pid, {:signal, fresh_signal})
    assert_receive {:objective_event, %{data: %{title: "fresh E2"}}}, 1_000
    refute_receive {:objective_event, %{data: %{title: "stale E1"}}}, 100
  end

  test "routes plural fan-out signals through durable objective ownership" do
    name = :"signal_bridge_fanout_#{System.unique_integer([:positive])}"
    start_supervised!({SignalBridge, name: name, validate_fun: fn _epoch -> :ok end})
    SignalBridge.open(name, epoch())
    assert_open(name)

    test_pid = self()

    alice_listener =
      spawn(fn ->
        Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, SignalBridge.topic_for("alice"))
        send(test_pid, :alice_listener_ready)
        forward_objective_events(test_pid)
      end)

    on_exit(fn -> Process.exit(alice_listener, :kill) end)
    assert_receive :alice_listener_ready

    Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, SignalBridge.topic_for("mallory"))

    assert {:ok, parent} =
             Objectives.create_objective(
               %{
                 user_id: "alice",
                 title: "Owned fan-out",
                 objective: "Route durable ownership",
                 fanout_role: "parent"
               },
               ReadyEffectContext.context()
             )

    assert :ok =
             Signals.emit_fanout(:run_progress, %{
               parent_id: parent.id,
               child_id: "child-not-required-for-owner-resolution",
               progress_summary: "halfway"
             })

    assert_receive {:alice_objective_event, received}, 1_000
    assert received.type == "allbert.objectives.run.progress"
    assert received.data.parent_id == parent.id

    assert :ok =
             Signals.emit_fanout(:run_progress, %{
               parent_id: parent.id,
               user_id: "mallory",
               progress_summary: "forged owner"
             })

    assert_receive {:alice_objective_event,
                    %{data: %{progress_summary: "forged owner"}} = forged},
                   1_000

    assert forged.data.parent_id == parent.id
    refute_receive {:objective_event, %{data: %{progress_summary: "forged owner"}}}, 200

    assert :ok = Signals.emit_fanout(:run_progress, %{parent_id: "unknown-parent"})
    refute_receive {:objective_event, %{data: %{parent_id: "unknown-parent"}}}, 200
  end

  test "broadcasts objective events, fragment envelopes, and generic workspace signals" do
    name = :"signal_bridge_#{System.unique_integer([:positive])}"
    start_supervised!({SignalBridge, name: name, validate_fun: fn _epoch -> :ok end})
    SignalBridge.open(name, epoch())
    assert_open(name)

    user_topic = SignalBridge.topic_for("alice")
    workspace_topic = SignalBridge.workspace_topic_for("alice", "thread-signal-bridge")
    Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, user_topic)
    Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, workspace_topic)

    assert {:ok, signal} =
             Signals.objective_lifecycle(:created, %{
               objective_id: "obj_signal_bridge",
               user_id: "alice",
               title: "Analyze AAPL"
             })

    :ok = Signals.log(signal)

    assert_receive {:objective_event, received}, 1_000
    assert received.type == "allbert.objective.created"
    assert received.data.objective_id == "obj_signal_bridge"

    envelope = envelope()

    assert {:ok, fragment_signal} =
             Signal.new(
               "allbert.workspace.fragment.emitted",
               %{
                 user_id: "alice",
                 thread_id: "thread-signal-bridge",
                 envelope: envelope
               },
               source: "/allbert/workspace/test"
             )

    :ok = Signals.log(fragment_signal)

    assert_receive {:fragment, received_fragment}, 1_000
    assert received_fragment.id == envelope.id
    assert received_fragment.thread_id == "thread-signal-bridge"

    # v0.52: the receiver validates and broadcasts the envelope for rendering but
    # does not persist it — the emitter is the persistence authority (ADR 0023
    # v0.52 amendment). A hand-published bus signal that never went through
    # `Fragment.emit/1` therefore produces no `tile.added`; that signal
    # originates from the emitter-side Canvas persist.
    refute_receive {:workspace_event, %{type: "allbert.workspace.tile.added"}}, 200

    assert {:ok, workspace_signal} =
             Signal.new(
               "allbert.workspace.fragment.dropped",
               %{user_id: "alice", thread_id: "thread-signal-bridge", reason: :surface_invalid},
               source: "/allbert/workspace/test"
             )

    :ok = Signals.log(workspace_signal)

    received_workspace = receive_workspace_event("allbert.workspace.fragment.dropped")
    assert received_workspace.type == "allbert.workspace.fragment.dropped"
    assert received_workspace.data.reason == :surface_invalid

    assert {:ok, runtime_signal} =
             Signals.runtime_turn_started(%{user_id: "alice", trace_id: "trace_signal_bridge"})

    :ok = Signals.log(runtime_signal)
    refute_receive {:objective_event, %{type: "allbert.runtime.turn.started"}}, 100
  end

  test "does not raise on malformed fragment payloads" do
    name = :"signal_bridge_malformed_#{System.unique_integer([:positive])}"
    start_supervised!({SignalBridge, name: name, validate_fun: fn _epoch -> :ok end})
    SignalBridge.open(name, epoch())
    assert_open(name)

    topic = SignalBridge.workspace_topic_for("alice", "thread-signal-bridge")
    Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, topic)

    assert {:ok, signal} =
             Signal.new(
               "allbert.workspace.fragment.emitted",
               %{user_id: "alice", thread_id: "thread-signal-bridge", envelope: %{bad: true}},
               source: "/allbert/workspace/test"
             )

    :ok = Signals.log(signal)

    refute_receive {:workspace_event, %{type: "allbert.workspace.fragment.emitted"}}, 100
    refute_receive {:fragment, _envelope}, 100
  end

  test "starts safely when signal bus subscription fails" do
    name = :"signal_bridge_failed_#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {SignalBridge,
         name: name,
         subscribe_fun: fn AllbertAssist.SignalBus, _pattern ->
           {:error, :bus_unavailable}
         end,
         validate_fun: fn _epoch -> :ok end}
      )

    assert Process.alive?(pid)
  end

  defp envelope do
    secret = SigningSecret.ensure!()

    assert {:ok, envelope} =
             Envelope.sign(
               %{
                 id: "frag_signal_bridge",
                 surface: %Surface{
                   id: :fragment,
                   app_id: :allbert,
                   label: "Fragment",
                   path: "/workspace",
                   kind: :canvas,
                   status: :available,
                   nodes: [
                     %Node{id: "fragment-text", component: :text, props: %{text: "hello"}}
                   ],
                   fallback_text: "Fragment fallback"
                 },
                 emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
                 user_id: "alice",
                 thread_id: "thread-signal-bridge",
                 scope: :canvas,
                 kind: :text,
                 emitted_at: ~U[2026-05-18 00:00:00Z]
               },
               secret
             )

    envelope
  end

  defp epoch, do: epoch("a")

  defp epoch(digest_character) do
    %{barrier_pid: self(), snapshot_digest: String.duplicate(digest_character, 64)}
  end

  defp assert_open(name, attempts \\ 20)

  defp assert_open(name, attempts) when attempts > 0 do
    if map_size(:sys.get_state(name).subscription_ids) == 3 do
      :ok
    else
      Process.sleep(10)
      assert_open(name, attempts - 1)
    end
  end

  defp assert_open(_name, 0), do: flunk("signal bridge did not open its epoch subscriptions")

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp receive_workspace_event(type) do
    receive do
      {:workspace_event, %{type: ^type} = signal} -> signal
      {:workspace_event, _signal} -> receive_workspace_event(type)
    after
      1_000 -> flunk("expected workspace event #{type}")
    end
  end

  defp forward_objective_events(test_pid) do
    receive do
      {:objective_event, signal} ->
        send(test_pid, {:alice_objective_event, signal})
        forward_objective_events(test_pid)
    end
  end
end
