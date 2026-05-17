defmodule AllbertAssistWeb.SignalBridgeTest do
  use AllbertAssistWeb.ConnCase, async: false

  alias AllbertAssist.Signals
  alias AllbertAssistWeb.SignalBridge

  test "broadcasts objective signals to user topics and ignores non-objective signals" do
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
         subscribe_fun: fn AllbertAssist.SignalBus, "allbert.objective.**" ->
           {:error, :bus_unavailable}
         end}
      )

    assert Process.alive?(pid)
  end
end
