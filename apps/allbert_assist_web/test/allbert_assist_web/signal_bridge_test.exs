defmodule AllbertAssistWeb.SignalBridgeTest do
  use AllbertAssistWeb.ConnCase, async: false

  alias AllbertAssist.Signals
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Fragment.Envelope
  alias AllbertAssistWeb.SignalBridge
  alias Jido.Signal

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

    topic = SignalBridge.topic_for("alice")
    Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, topic)

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

    assert {:ok, workspace_signal} =
             Signal.new(
               "allbert.workspace.fragment.dropped",
               %{user_id: "alice", thread_id: "thread-signal-bridge", reason: :surface_invalid},
               source: "/allbert/workspace/test"
             )

    :ok = Signals.log(workspace_signal)

    assert_receive {:workspace_event, received_workspace}, 1_000
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

    topic = SignalBridge.topic_for("alice")
    Phoenix.PubSub.subscribe(AllbertAssistWeb.PubSub, topic)

    assert {:ok, signal} =
             Signal.new(
               "allbert.workspace.fragment.emitted",
               %{user_id: "alice", thread_id: "thread-signal-bridge", envelope: %{bad: true}},
               source: "/allbert/workspace/test"
             )

    :ok = Signals.log(signal)

    assert_receive {:workspace_event, received_workspace}, 1_000
    assert received_workspace.type == "allbert.workspace.fragment.emitted"
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
    %Envelope{
      id: "frag_signal_bridge",
      surface: %Surface{
        id: :fragment,
        app_id: :allbert,
        label: "Fragment",
        path: "/agent",
        kind: :canvas,
        status: :available,
        nodes: [%Node{id: "fragment-text", component: :text, props: %{text: "hello"}}],
        fallback_text: "Fragment fallback"
      },
      emitter_id: "AllbertAssist.Actions.Intent.DirectAnswer",
      user_id: "alice",
      thread_id: "thread-signal-bridge",
      scope: :canvas,
      kind: :text,
      emitted_at: ~U[2026-05-18 00:00:00Z],
      signature: "already-validated"
    }
  end
end
