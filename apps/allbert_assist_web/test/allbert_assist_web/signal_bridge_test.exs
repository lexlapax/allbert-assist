defmodule AllbertAssistWeb.SignalBridgeTest do
  use AllbertAssistWeb.ConnCase, async: false

  alias AllbertAssist.Signals
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

  test "broadcasts objective and workspace signals to user topics" do
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

    assert {:ok, workspace_signal} =
             Signal.new(
               "allbert.workspace.fragment.emitted",
               %{user_id: "alice", thread_id: "thread-signal-bridge"},
               source: "/allbert/workspace/test"
             )

    :ok = Signals.log(workspace_signal)

    assert_receive {:workspace_event, received_workspace}, 1_000
    assert received_workspace.type == "allbert.workspace.fragment.emitted"
    assert received_workspace.data.thread_id == "thread-signal-bridge"

    assert {:ok, runtime_signal} =
             Signals.runtime_turn_started(%{user_id: "alice", trace_id: "trace_signal_bridge"})

    :ok = Signals.log(runtime_signal)
    refute_receive {:objective_event, %{type: "allbert.runtime.turn.started"}}, 100
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
end
