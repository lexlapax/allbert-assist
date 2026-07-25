defmodule AllbertAssist.Objectives.FanoutTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  import Ecto.Query

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Lifecycle
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Objectives.Runs.CancelToken
  alias AllbertAssist.Repo

  defmodule CompletingAdapter do
    def operation(:execute, state, _opts),
      do: {:ok, Map.put(state, :response, %{message: "completed #{state.objective.title}"})}

    def operation(_operation, state, _opts), do: {:ok, state}
  end

  defmodule FailingAdapter do
    def operation(:execute, state, _opts), do: {:error, :fixture_failure, state}
    def operation(_operation, state, _opts), do: {:ok, state}
  end

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

  test "the last public lifecycle completion atomically joins its parent" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{user_id: "alice", title: "Atomic join", objective: "Run every child"},
               ["first", "second", "third"]
             )

    for child <- children do
      assert {:ok, %{status: "completed"}} =
               Lifecycle.run(child.id, adapter: CompletingAdapter)
    end

    assert {:ok, joined} = Objectives.get_objective(parent.id)
    assert joined.status == "completed"
    assert joined.join_outcome == "success"
    assert joined.report_delivery_state == "pending"
    assert is_binary(joined.report_delivery_receipt_digest)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "concurrent final siblings reduce to one join and one stable report receipt" do
    for iteration <- 1..12 do
      assert {:ok, %{parent: parent, children: children}} =
               Fanout.frame(
                 %{
                   user_id: "alice",
                   title: "Concurrent join #{iteration}",
                   objective: "Commit both final siblings"
                 },
                 ["first", "second"]
               )

      tasks =
        Enum.map(children, fn child ->
          Task.async(fn ->
            receive do: (:go -> :ok)

            TerminalTransitions.terminalize_child(
              child,
              %{
                status: "completed",
                last_observation_summary: "result #{child.queue_position}",
                completed_at: DateTime.utc_now()
              },
              "run_completed",
              %{}
            )
          end)
        end)

      Enum.each(tasks, &send(&1.pid, :go))

      assert Enum.all?(tasks, fn task ->
               match?({:ok, %{child: %{status: "completed"}}}, Task.await(task, 2_000))
             end)

      assert %{phase: :joined, parent: joined, children: terminal_children} =
               Fanout.parent_projection(parent)

      assert Enum.all?(terminal_children, &(&1.status == "completed"))
      assert joined.report_delivery_state == "pending"

      assert joined.report_delivery_receipt_digest ==
               :crypto.hash(:sha256, Fanout.receipt_for(:report, parent.id))
               |> Base.encode16(case: :lower)

      assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
    end
  end

  test "a public lifecycle failure atomically joins the mixed parent" do
    assert {:ok, %{parent: parent, children: [completed, failed]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Mixed atomic join", objective: "Run every child"},
               ["complete", "fail"]
             )

    assert {:ok, %{status: "completed"}} =
             Lifecycle.run(completed.id, adapter: CompletingAdapter)

    assert {:error, :fixture_failure} = Lifecycle.run(failed.id, adapter: FailingAdapter)

    assert {:ok, joined} = Objectives.get_objective(parent.id)
    assert joined.status == "completed"
    assert joined.join_outcome == "partial"
    assert joined.report_delivery_state == "pending"
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "a public lifecycle cancellation atomically joins the mixed parent" do
    assert {:ok, %{parent: parent, children: [completed, cancelled]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Cancelled atomic join", objective: "Run children"},
               ["complete", "cancel"]
             )

    assert {:ok, %{status: "completed"}} =
             Lifecycle.run(completed.id, adapter: CompletingAdapter)

    cancel_token = CancelToken.new()
    assert :ok = CancelToken.cancel(cancel_token)

    assert {:ok, %{status: "cancelled"}} =
             Lifecycle.run(cancelled.id,
               adapter: CompletingAdapter,
               cancel_token: cancel_token
             )

    assert {:ok, joined} = Objectives.get_objective(parent.id)
    assert joined.status == "completed"
    assert joined.join_outcome == "partial"
    assert joined.report_delivery_state == "pending"
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "join reduction and report enumerate partial outcomes" do
    assert {:ok, %{parent: parent, children: [first, second]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Parallel", objective: "Parallel"},
               ["First", "Second"]
             )

    assert {:ok, %{status: "completed"}} =
             Lifecycle.run(first.id, adapter: CompletingAdapter)

    assert {:error, :fixture_failure} = Lifecycle.run(second.id, adapter: FailingAdapter)

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

  test "an all-terminal open parent is repaired idempotently" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{user_id: "alice", title: "Historical orphan", objective: "Repair parent"},
               ["first", "second"]
             )

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    for child <- children do
      assert {1, _rows} =
               Objective
               |> where([objective], objective.id == ^child.id)
               |> Repo.update_all(
                 set: [
                   status: "completed",
                   last_observation_summary: "historical result",
                   completed_at: DateTime.utc_now()
                 ]
               )
    end

    assert {:ok, {:joined_now, joined}} = Fanout.reconcile_parent(parent.id)
    assert joined.status == "completed"
    assert joined.report_delivery_state == "pending"

    assert {:ok, {:already_joined, same_parent}} = Fanout.reconcile_parent(parent.id)
    assert same_parent.id == joined.id
    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "stale abandonment never starts or completes an undelivered fan-out" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{user_id: "alice", title: "Undelivered fan-out", objective: "Wait for delivery"},
               ["first", "second"]
             )

    stale = DateTime.add(DateTime.utc_now(), -2, :hour)

    assert {3, _rows} =
             Objective
             |> where([objective], objective.id in ^[parent.id | Enum.map(children, & &1.id)])
             |> Repo.update_all(set: [updated_at: stale])

    assert {:ok, 0} = Objectives.abandon_stale_objectives(now: DateTime.utc_now())

    assert %{phase: :awaiting_kickoff, parent: unchanged} = Fanout.parent_projection(parent)
    assert unchanged.report_delivery_state == "not_ready"
    assert Enum.all?(Fanout.children(parent), &(&1.status == "open"))
    refute Enum.any?(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined"))
  end

  test "stale abandonment terminalizes children and derives the parent once" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{user_id: "alice", title: "Stale fan-out", objective: "Recover stale work"},
               ["first", "second"]
             )

    assert :ok = Fanout.acknowledge_start(receipt, %{user_id: "alice"})

    stale = DateTime.add(DateTime.utc_now(), -2, :hour)
    ids = [parent.id | Enum.map(children, & &1.id)]

    assert {3, _rows} =
             Objective
             |> where([objective], objective.id in ^ids)
             |> Repo.update_all(set: [updated_at: stale])

    assert {:ok, 2} = Objectives.abandon_stale_objectives(now: DateTime.utc_now())

    assert Enum.all?(children, fn child ->
             match?({:ok, %{status: "abandoned"}}, Objectives.get_objective(child.id))
           end)

    assert {:ok,
            %{
              status: "failed",
              join_outcome: "failed",
              report_delivery_state: "pending"
            }} = Objectives.get_objective(parent.id)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "child report detail is bounded and prioritizes truthful terminal reasons" do
    assert Fanout.report_child_detail(%{
             status: "completed",
             result_summary: String.duplicate("x", 600),
             review_reason: nil
           }) == String.duplicate("x", 500)

    assert Fanout.report_child_detail(%{
             status: "cancelled",
             result_summary: "stale progress",
             review_reason: "cancelled by operator"
           }) == "cancelled by operator"

    assert Fanout.report_child_detail(%{status: "failed"}) ==
             "No terminal reason recorded."
  end

  test "one durable parent projection distinguishes running, recovery, joined, and corruption" do
    assert {:ok, %{parent: parent, children: children, fanout_start_receipt: receipt}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_channel: "tui",
                 source_thread_id: "projection-thread",
                 title: "Projection truth",
                 objective: "Project one durable fan-out"
               },
               ["first", "second"]
             )

    assert %{
             phase: :awaiting_kickoff,
             children_terminal?: false,
             authoritatively_joined?: false,
             recovery_required?: false
           } = Fanout.parent_projection(parent)

    assert :ok =
             Fanout.acknowledge_start(receipt, %{
               user_id: "alice",
               channel: "tui",
               thread_id: "projection-thread"
             })

    assert %{phase: :running, display_status: "running", recovery_required?: true} =
             Fanout.parent_projection(parent)

    # Simulate the exact pre-M12.15 crash orphan: child terminal rows committed,
    # but the parent reduction did not. Production writers cannot create this.
    assert {2, _rows} =
             Objective
             |> where([objective], objective.id in ^Enum.map(children, & &1.id))
             |> Repo.update_all(
               set: [
                 status: "completed",
                 last_observation_summary: "durable result",
                 completed_at: DateTime.utc_now()
               ]
             )

    assert %{
             phase: :recovering,
             display_status: "finalizing",
             children_terminal?: true,
             authoritatively_joined?: false
           } = Fanout.parent_projection(parent)

    assert {:ok, {:joined_now, joined}} = Fanout.reconcile_parent(parent)

    assert %{
             phase: :joined,
             display_status: "completed",
             authoritatively_joined?: true,
             persisted_join_outcome: "success",
             derived_join_outcome: "success"
           } = Fanout.parent_projection(joined)

    # A durable report marker whose parent reduction disagrees with its children
    # is corruption, never an active or successfully joined projection.
    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [join_outcome: "partial"])

    assert %{phase: :inconsistent, display_status: "inconsistent"} =
             Fanout.parent_projection(parent)
  end

  test "an empty fan-out parent is inconsistent rather than terminal" do
    assert {:ok, parent} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Empty parent",
               objective: "No children",
               fanout_role: "parent"
             })

    assert %{
             phase: :inconsistent,
             children: [],
             children_terminal?: false,
             authoritatively_joined?: false
           } = Fanout.parent_projection(parent)
  end

  test "pending report reads exclude a corrupted non-joined parent" do
    assert {:ok, %{parent: parent}} =
             Fanout.frame(
               %{
                 user_id: "alice",
                 source_thread_id: "corrupt-report-thread",
                 title: "Corrupt outbox",
                 objective: "Never present a false report"
               },
               ["one", "two"]
             )

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 status: "completed",
                 join_outcome: "success",
                 report_delivery_state: "pending",
                 completed_at: DateTime.utc_now()
               ]
             )

    assert Fanout.parent_projection(parent).phase == :inconsistent
    assert Fanout.pending_reports("alice", "corrupt-report-thread", %{channel: "test"}) == []
  end

  test "joined projection requires its durable receipt and join event" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               %{user_id: "alice", title: "Join integrity", objective: "Join integrity"},
               ["one", "two"]
             )

    Enum.each(children, fn child ->
      assert {:ok, _transition} =
               TerminalTransitions.terminalize_child(
                 child,
                 %{status: "completed", completed_at: DateTime.utc_now()},
                 "run_completed",
                 %{}
               )
    end)

    assert Fanout.parent_projection(parent).phase == :joined

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(set: [report_delivery_receipt_digest: nil])

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)

    assert {1, _rows} =
             Objective
             |> where([objective], objective.id == ^parent.id)
             |> Repo.update_all(
               set: [
                 report_delivery_receipt_digest:
                   :crypto.hash(:sha256, Fanout.receipt_for(:report, parent.id))
                   |> Base.encode16(case: :lower)
               ]
             )

    assert {1, _rows} =
             AllbertAssist.Objectives.Event
             |> where([event], event.objective_id == ^parent.id and event.kind == "fanout_joined")
             |> Repo.delete_all()

    assert %{phase: :inconsistent, authoritatively_joined?: false} =
             Fanout.parent_projection(parent)
  end

  test "orphan terminal children project inconsistent without crashing" do
    parent_id = "fanout_missing_parent"

    for {id, position} <- [{"obj_orphan_one", 0}, {"obj_orphan_two", 1}] do
      assert {:ok, _child} =
               Objectives.create_objective(%{
                 id: id,
                 user_id: "alice",
                 title: id,
                 objective: id,
                 fanout_role: "child",
                 parent_objective_id: parent_id,
                 queue_position: position,
                 status: "completed",
                 completed_at: DateTime.utc_now()
               })
    end

    assert %{phase: :inconsistent, parent: nil, children_terminal?: true} =
             Fanout.parent_projection(parent_id)
  end

  test "generic objective updates cannot bypass fan-out terminal authority" do
    assert {:ok, %{parent: parent, children: [child, _sibling]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Guard authority", objective: "Guard authority"},
               ["first", "second"]
             )

    assert {:error, :fanout_active_transition_required} =
             Objectives.update_objective(child, %{status: "completed"})

    assert {:error, :fanout_parent_transition_required} =
             Objectives.update_objective(parent, %{
               status: "completed",
               join_outcome: "success",
               report_delivery_state: "pending"
             })

    assert {:error, :fanout_active_transition_required} =
             Objectives.update_objective(child, %{status: "running"})

    assert {:ok, %{status: "running"}} =
             TerminalTransitions.transition_active_child(
               child,
               %{status: "running"},
               "run_started",
               %{attempt: 1}
             )
  end

  test "a stale active struct cannot reopen a terminal child" do
    assert {:ok, %{parent: parent, children: [stale, sibling]}} =
             Fanout.frame(
               %{user_id: "alice", title: "Race guard", objective: "Race guard"},
               ["first", "second"]
             )

    assert {:ok, %{child: %{status: "completed"}}} =
             TerminalTransitions.terminalize_child(
               stale,
               %{status: "completed", completed_at: DateTime.utc_now()},
               "run_completed",
               %{}
             )

    assert {:error, {:fanout_active_compare_and_set_failed, "completed"}} =
             Objectives.update_objective(stale, %{progress_summary: "stale writer"})

    assert {:error, {:active_transition_compare_and_set_failed, "completed"}} =
             TerminalTransitions.transition_active_child(
               stale,
               %{status: "running"},
               "run_started",
               %{attempt: 2}
             )

    assert {:ok, %{child: %{status: "completed"}}} =
             TerminalTransitions.terminalize_child(
               sibling,
               %{status: "completed", completed_at: DateTime.utc_now()},
               "run_completed",
               %{}
             )

    assert {:ok, %{status: "completed"}} = Objectives.get_objective(stale.id)

    assert {:ok, %{status: "completed", join_outcome: "success"}} =
             Objectives.get_objective(parent.id)

    assert Enum.count(Objectives.list_events(parent.id), &(&1.kind == "fanout_joined")) == 1
  end

  test "unique receipt digests and fanout value domains are enforced" do
    attrs = %{user_id: "alice", title: "One", objective: "One", fanout_role: "parent"}

    assert {:ok, _first} =
             Objectives.create_objective(Map.put(attrs, :fanout_start_receipt_digest, "same"))

    assert {:error, changeset} =
             Objectives.create_objective(Map.put(attrs, :fanout_start_receipt_digest, "same"))

    assert "has already been taken" in errors_on(changeset).fanout_start_receipt_digest

    assert {:error, invalid} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Invalid",
               objective: "Invalid",
               fanout_role: "parent",
               kickoff_delivery_state: "sent"
             })

    assert "is invalid" in errors_on(invalid).kickoff_delivery_state
  end
end
