defmodule AllbertAssist.Objectives.FanoutSteeringTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Steering

  test "directive is ownership-bound, durable, idempotent, and applied at a boundary" do
    {:ok, %{children: [child | _]}} =
      Fanout.frame(%{user_id: "alice", title: "Work", objective: "Work"}, ["One", "Two"])

    assert {:error, :not_found} = Steering.steer("mallory", child.id, "Do something else")

    assert {:ok, %{directive_event: directive}} =
             Steering.steer("alice", child.id, "Use primary sources")

    assert {:ok, updated} = Steering.apply_pending(child.id)
    assert updated.objective == "Use primary sources"

    assert Enum.map(Objectives.list_events(child.id), & &1.kind) == [
             "steer_applied",
             "steer_directive"
           ]

    assert {:ok, _} = Steering.apply_pending(child.id)
    assert Enum.count(Objectives.list_events(child.id), &(&1.kind == "steer_applied")) == 1
    assert is_binary(directive.id)
  end

  test "terminal objectives reject steering" do
    {:ok, objective} =
      Objectives.create_objective(%{
        user_id: "alice",
        title: "Done",
        objective: "Done",
        status: "completed"
      })

    assert {:error, :terminal} = Steering.steer("alice", objective.id, "Again")
  end
end
