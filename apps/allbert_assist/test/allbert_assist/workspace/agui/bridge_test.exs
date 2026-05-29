defmodule AllbertAssist.Workspace.AGUI.BridgeTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Workspace.AGUI.Bridge
  alias Jido.Signal

  @mapping_cases [
    {"allbert.runtime.turn.started", "LIFECYCLE_START", %{trace_id: "trace-1"}},
    {"allbert.runtime.turn.completed", "LIFECYCLE_END", %{trace_id: "trace-1"}},
    {"allbert.confirmation.requested", "INTERRUPT",
     %{confirmation_id: "conf-1", reason: "Needs approval"}},
    {"allbert.confirmation.approved", "INTERRUPT_RESPONSE", %{confirmation_id: "conf-1"}},
    {"allbert.confirmation.denied", "INTERRUPT_RESPONSE", %{confirmation_id: "conf-1"}},
    {"allbert.objective.observed", "STATE_DELTA",
     %{objective_id: "obj-1", observation_summary: "Collected evidence"}},
    {"allbert.objective.completed", "STATE_SNAPSHOT",
     %{objective_id: "obj-1", progress_summary: "Done"}},
    {"allbert.action.requested", "TOOL_CALL_START",
     %{action_name: "direct_answer", params: %{api_key: "sk-test"}}},
    {"allbert.action.completed", "TOOL_CALL_END",
     %{action_name: "direct_answer", status: :completed}},
    {"allbert.action.failed", "TOOL_CALL_ERROR",
     %{action_name: "direct_answer", error: {:boom, :bad_input}}}
  ]

  test "translates the 10 documented Allbert to AG-UI mappings" do
    for {allbert_type, agui_type, data} <- @mapping_cases do
      assert {:ok, signal} = signal(allbert_type, data)
      assert {:ok, event} = Bridge.translate(signal)

      assert event["type"] == agui_type
      assert event["signal"]["type"] == allbert_type
      assert event["signal"]["source"] == "/allbert/agui/test"
      assert event["data"] == Jason.decode!(Jason.encode!(event["data"]))
      assert Jason.encode!(event)
    end
  end

  test "adds mapping-specific fields" do
    assert {:ok, requested} =
             signal("allbert.confirmation.requested", %{
               confirmation_id: "conf-1",
               reason: "Needs approval"
             })

    assert {:ok, interrupt} = Bridge.translate(requested)
    assert interrupt["interrupt_id"] == "conf-1"
    assert interrupt["reason"] == "Needs approval"

    assert {:ok, approved} = signal("allbert.confirmation.approved", %{id: "conf-1"})
    assert {:ok, approved_event} = Bridge.translate(approved)
    assert approved_event["response"] == "approve"

    assert {:ok, denied} = signal("allbert.confirmation.denied", %{id: "conf-1"})
    assert {:ok, denied_event} = Bridge.translate(denied)
    assert denied_event["response"] == "reject"

    assert {:ok, action} =
             signal("allbert.action.requested", %{
               action_name: "direct_answer",
               params: %{api_key: "sk-test"}
             })

    assert {:ok, tool_call} = Bridge.translate(action)
    assert tool_call["tool_call_id"] == "direct_answer"
    assert tool_call["tool_name"] == "direct_answer"
    assert tool_call["data"]["params"]["api_key"] == "[REDACTED]"

    assert {:ok, observed} =
             signal("allbert.objective.observed", %{objective_id: "obj-1", loop_count: 2})

    assert {:ok, delta} = Bridge.translate(observed)
    assert delta["state"]["delta"]["objective_id"] == "obj-1"
    assert delta["state"]["delta"]["loop_count"] == 2
  end

  test "returns no_mapping for representative unmapped signals" do
    for type <- [
          "allbert.runtime.turn.started.debug",
          "allbert.workspace.fragment.emitted",
          "third.party.event"
        ] do
      assert {:ok, signal} = signal(type, %{id: "unmapped"})
      assert {:error, :no_mapping} = Bridge.translate(signal)
    end

    assert {:error, :no_mapping} = Bridge.translate(%{type: "allbert.runtime.turn.started"})
  end

  defp signal(type, data) do
    Signal.new(type, data, source: "/allbert/agui/test", subject: "local")
  end
end
