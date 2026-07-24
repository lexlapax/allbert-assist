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

  test "terminal fan-in identifies the effective steered child and its result" do
    {:ok, %{parent: parent, children: [child | _]}} =
      Fanout.frame(%{user_id: "alice", title: "Work", objective: "Work"}, ["One", "Two"])

    assert {:ok, _steer} =
             Steering.steer("alice", child.id, "Explain OTP supervision as a restaurant analogy")

    assert {:ok, steered} = Steering.apply_pending(child.id)

    assert {:ok, _completed} =
             Objectives.update_objective(steered, %{
               status: "completed",
               last_observation_summary: "The supervisor is the restaurant manager.",
               completed_at: DateTime.utc_now()
             })

    [_steered_child, other] = Fanout.children(parent)

    assert {:ok, _completed} =
             Objectives.update_objective(other, %{
               status: "completed",
               last_observation_summary: "Second result",
               completed_at: DateTime.utc_now()
             })

    report = Fanout.report(parent)
    [steered_report | _] = report.children

    assert steered_report.title == "Explain OTP supervision as a restaurant analogy"
    assert steered_report.result_summary == "The supervisor is the restaurant manager."
  end
end
