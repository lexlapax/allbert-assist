defmodule AllbertAssist.Objectives.FanoutTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout

  test "frames parent and ordered children atomically without starting them" do
    assert {:ok, %{parent: parent, children: [first, second], fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_thread_id: "thread-1",
                 source_channel: "telegram",
                 source_surface: "channel",
                 session_id: "session-1",
                 title: "Parallel work",
                 objective: "Do both tasks"
               },
               ["Research the topic", "Draft the summary"]
             )

    assert parent.fanout_role == "parent"
    assert parent.kickoff_delivery_state == "pending"
    assert parent.report_delivery_state == "not_ready"
    assert is_binary(receipt)
    refute parent.fanout_start_receipt_digest == receipt

    assert Enum.map([first, second], & &1.queue_position) == [0, 1]
    assert Enum.all?([first, second], &(&1.parent_objective_id == parent.id))
    assert Enum.all?([first, second], &(&1.status == "open"))
    assert Enum.map(Fanout.children(parent), & &1.id) == [first.id, second.id]

    identity = %{user_id: "alice", channel: "telegram", thread_id: "thread-1"}
    assert :ok = Fanout.acknowledge_start(receipt, identity)
    assert :ok = Fanout.acknowledge_start(receipt, identity)

    assert {:error, :receipt_identity_mismatch} =
             Fanout.acknowledge_start(receipt, Map.put(identity, :user_id, "mallory"))

    assert Enum.map(Objectives.list_events(parent.id), & &1.kind) == [
             "fanout_acknowledged",
             "fanout_proposed"
           ]
  end

  test "invalid child set rolls back the parent" do
    before_count = length(Objectives.list_objectives("alice"))

    assert {:error, :fanout_requires_at_least_two_children} =
             Fanout.frame(%{user_id: "alice", title: "Nope", objective: "Nope"}, ["one"])

    assert length(Objectives.list_objectives("alice")) == before_count
  end

  test "join reduction and report enumerate partial outcomes" do
    assert {:ok, %{parent: parent, children: [first, second]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Parallel", objective: "Parallel"},
               ["First", "Second"]
             )

    assert {:ok, _} =
             Objectives.update_objective(first, %{
               status: "completed",
               last_observation_summary: "done"
             })

    assert {:ok, _} =
             Objectives.update_objective(second, %{status: "failed", review_reason: "boom"})

    assert %{terminal?: true, status: "completed", outcome: "partial"} =
             Fanout.join_status(parent)

    assert {:ok, %{parent: joined, report_delivery_receipt: report_receipt}} =
             Fanout.finalize_join(parent)

    assert joined.join_outcome == "partial"
    assert joined.report_delivery_state == "pending"
    assert :ok = Fanout.acknowledge_report(report_receipt, %{user_id: "alice"})
    assert :ok = Fanout.acknowledge_report(report_receipt, %{user_id: "alice"})

    assert Enum.map(Objectives.list_events(parent.id), & &1.kind) == [
             "report_delivered",
             "fanout_joined",
             "fanout_proposed"
           ]

    assert %{children: children, join_outcome: "partial"} = Fanout.report(parent)
    assert Enum.map(children, & &1.status) == ["completed", "failed"]
  end

  test "unique receipt digests and fanout value domains are enforced" do
    attrs = %{user_id: "alice", title: "One", objective: "One", fanout_role: "parent"}

    assert {:ok, first} =
             Objectives.create_objective(Map.put(attrs, :fanout_start_receipt_digest, "same"))

    assert {:error, changeset} =
             Objectives.create_objective(Map.put(attrs, :fanout_start_receipt_digest, "same"))

    assert "has already been taken" in errors_on(changeset).fanout_start_receipt_digest

    assert {:error, invalid} =
             Objectives.update_objective(first, %{kickoff_delivery_state: "sent"})

    assert "is invalid" in errors_on(invalid).kickoff_delivery_state
  end
end
