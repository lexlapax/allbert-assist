defmodule AllbertAssistWeb.SignalBridgeTest do
  use AllbertAssistWeb.ConnCase, async: false

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssist.Workspace.Fragment.Guard
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias AllbertAssistWeb.SignalBridge
  alias Jido.Signal

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "signal-bridge-test-#{System.unique_integer([:positive])}")

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
       end}
    )

    assert_receive {:subscribed, "allbert.objective.**"}
    assert_receive {:subscribed, "allbert.workspace.**"}
  end

  test "broadcasts objective events, fragment envelopes, and generic workspace signals" do
    name = :"signal_bridge_#{System.unique_integer([:positive])}"
    start_supervised!({SignalBridge, name: name})

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

    assert_receive {:workspace_event, tile_signal}, 1_000
    assert tile_signal.type == "allbert.workspace.tile.added"

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
    start_supervised!({SignalBridge, name: name})

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
         end}
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
end
