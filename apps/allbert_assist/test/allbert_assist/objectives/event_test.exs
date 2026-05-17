defmodule AllbertAssist.Objectives.EventTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Event

  setup do
    {:ok, objective} =
      Objectives.create_objective(%{
        user_id: "alice",
        title: "Analyze AAPL",
        objective: "Complete one analysis for AAPL."
      })

    %{objective: objective}
  end

  test "creates objective events with redacted bounded payloads", %{objective: objective} do
    assert {:ok, event} =
             Objectives.create_event(%{
               objective_id: objective.id,
               kind: "created",
               summary: "Objective created.",
               payload: %{api_key: "sk-test", title: "Analyze AAPL"}
             })

    assert event.kind == "created"
    assert event.payload =~ "[REDACTED]"
    refute event.payload =~ "sk-test"
    assert [%Event{id: id}] = Objectives.list_events(objective.id)
    assert id == event.id
  end

  test "changeset rejects unknown event kinds and missing objective ids" do
    changeset =
      Event.changeset(%Event{}, %{
        id: Objectives.new_id("evt"),
        kind: "future_kind",
        recorded_at: DateTime.utc_now()
      })

    refute changeset.valid?
    assert %{objective_id: [_], kind: [_]} = errors_on(changeset)
  end
end
