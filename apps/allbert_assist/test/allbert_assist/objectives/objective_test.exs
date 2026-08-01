defmodule AllbertAssist.Objectives.ObjectiveTest do
  # v1.0.3 M1 pilot conversion (ADR 0086 contract 1): db_serial →
  # db_partition_safe. `async: true` starts a NON-shared sandbox owner per
  # test, so sandbox access is per-test ownership instead of VM-ambient
  # shared mode. Red-first serial-requirement proof (recorded in the plan's
  # M1 Build Progress entry):
  #   (a) flipping only `async: true` fails "public facade scopes reads…"
  #       with DBConnection.OwnershipError — Objectives.frame/cancel
  #       delegate through the long-lived Engine agent, whose Jido.Exec
  #       Task.Supervised children carry the agent (not the test) in
  #       `$callers`; and
  #   (b) under the old `async: false` shared mode the "contract-1
  #       ownership proof" test below is RED: an out-of-chain process gets
  #       ambient sandbox access, i.e. the file had NO ownership fence and
  #       needed the serial db_serial lane.
  # The conversion grants the engine agent an explicit per-test allowance
  # (`allow_sandbox/2`, DataCase). Repo-backed tests stay in the
  # partitioned db lane — never pure_async (SQLite single-writer).
  use AllbertAssist.DataCase, async: true, lane: :db_partition_safe

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AcceptanceCriteria
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Fanout.TerminalTransitions
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo

  @fixtures Path.expand("../../fixtures/v0.24/acceptance_criteria", __DIR__)

  setup do
    # Contract-1 allowance: the engine agent is a supervised singleton; its
    # delegate tasks resolve sandbox ownership through the agent's
    # `$callers`, so the agent itself must be allowed on this test's owner.
    allow_sandbox(AllbertAssist.Objectives.Engine.Agent)
    :ok
  end

  test "acceptance criteria fixtures round-trip through JSON validation" do
    for file <- ["single_step_run_analysis.json", "two_step_stocksage_compare.json"] do
      criteria = @fixtures |> Path.join(file) |> File.read!() |> Jason.decode!()

      assert :ok = AcceptanceCriteria.validate(criteria)

      encoded = AcceptanceCriteria.encode!(criteria)
      assert {:ok, ^criteria} = AcceptanceCriteria.decode(encoded)
    end
  end

  test "unknown acceptance criteria clause kinds are rejected" do
    invalid =
      AcceptanceCriteria.single_step()
      |> put_in(["required"], [%{"kind" => "future_clause"}])
      |> Jason.encode!()

    changeset =
      Objective.changeset(%Objective{}, %{
        id: Objectives.new_id("obj"),
        user_id: "alice",
        title: "Analyze AAPL",
        objective: "Complete one analysis for AAPL.",
        acceptance_criteria: invalid
      })

    refute changeset.valid?
    assert %{acceptance_criteria: [_]} = errors_on(changeset)
  end

  test "creates, scopes, lists, and abandons objectives" do
    user = unique_user("objective")
    other_user = unique_user("other")

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: user,
               source_thread_id: "thr_a",
               active_app: "stocksage",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               acceptance_criteria: AcceptanceCriteria.single_step()
             })

    assert objective.status == "open"
    assert objective.loop_count == 0
    assert {:ok, ^objective} = Objectives.get_objective(user, objective.id)
    assert {:error, :not_found} = Objectives.get_objective(other_user, objective.id)

    assert [listed] = Objectives.list_objectives(user, active_app: "stocksage")
    assert listed.id == objective.id
    assert [] = Objectives.list_objectives(other_user)

    stale = DateTime.add(DateTime.utc_now(), -2, :hour)

    assert {1, _} =
             Objective
             |> where([objective], objective.id == ^objective.id)
             |> Repo.update_all(set: [updated_at: stale])

    assert {:ok, 1} = Objectives.abandon_stale_objectives(now: DateTime.utc_now())
    assert {:ok, abandoned} = Objectives.get_objective(objective.id)
    assert abandoned.status == "abandoned"
  end

  test "public facade scopes reads and delegates lifecycle transitions to the engine" do
    user = unique_user("facade")
    other_user = unique_user("facade_other")

    assert {:ok, %{objective: framed}} =
             Objectives.frame(
               %{
                 user_id: user,
                 thread_id: "thr_facade",
                 session_id: "sess_facade",
                 active_app: :stocksage,
                 title: "Facade objective",
                 objective: "Complete a facade objective."
               },
               %{}
             )

    assert framed.user_id == user
    assert framed.source_thread_id == "thr_facade"
    assert framed.active_app == "stocksage"

    assert {:ok, [listed]} = Objectives.list(user, %{"active_app" => "stocksage"})
    assert listed.id == framed.id
    assert {:ok, ^framed} = Objectives.get(user, framed.id)
    assert {:error, :not_found} = Objectives.get(other_user, framed.id)

    assert {:ok, %{objective: cancelled}} =
             Objectives.cancel(user, framed.id, "facade test complete")

    assert cancelled.status == "cancelled"
  end

  test "public facade requires explicit user identity when framing" do
    assert {:error, :missing_user_id} =
             Objectives.frame(%{title: "No user", objective: "Do not silently default."}, %{})
  end

  test "objective preserves the canonical fanout request through 4,000 graphemes" do
    base = %{
      id: Objectives.new_id("obj"),
      user_id: "alice",
      title: "Bounded request",
      objective: String.duplicate("x", 4_000)
    }

    assert Objective.changeset(%Objective{}, base).valid?

    refute Objective.changeset(%Objective{}, %{base | objective: base.objective <> "x"}).valid?
  end

  test "generic active-child updates cannot rewrite inherited fanout structure or identity" do
    parent_attrs = %{
      user_id: unique_user("immutable_child"),
      source_thread_id: "thread-original",
      source_channel: "tui",
      source_surface: "operator",
      session_id: "session-original",
      active_app: "allbert",
      source_intent: "Compare both tasks.",
      origin_thread_ref_id: "origin-thread",
      origin_thread_ref_digest: "origin-digest",
      origin_receiver_account_ref: "receiver-ref",
      title: "Immutable fanout",
      objective: "Compare both tasks."
    }

    tasks = [
      %{
        title: "First task",
        objective: "Complete the first task.",
        acceptance_criteria: AcceptanceCriteria.encode!(%{"summary" => "First result."}),
        constraints: Jason.encode!(%{"scope" => "first"}),
        proposer_hint: %{"fanout_child" => %{"version" => 1}}
      },
      %{title: "Second task", objective: "Complete the second task."}
    ]

    assert {:ok, %{children: [child, _sibling]}} = Fanout.frame(parent_attrs, tasks)

    protected_updates = %{
      user_id: "other-user",
      source_thread_id: "other-thread",
      source_channel: "web",
      source_surface: "other-surface",
      session_id: "other-session",
      active_app: "other-app",
      title: "Changed title",
      objective: "Changed objective",
      acceptance_criteria: AcceptanceCriteria.encode!(%{"summary" => "Changed result."}),
      constraints: Jason.encode!(%{"scope" => "changed"}),
      proposer_hint: %{"fanout_child" => %{"version" => 2}},
      source_intent: "Changed source intent",
      fanout_role: "parent",
      parent_objective_id: Objectives.new_id("fanout"),
      join_policy: "all_terminal",
      join_outcome: "success",
      kickoff_delivery_state: "acknowledged",
      fanout_start_receipt_digest: "changed-start-receipt",
      report_delivery_state: "pending",
      report_delivery_receipt_digest: "changed-report-receipt",
      origin_thread_ref_id: "changed-origin-thread",
      origin_thread_ref_digest: "changed-origin-digest",
      origin_receiver_account_ref: "changed-receiver",
      queue_position: 1,
      completed_at: DateTime.utc_now(),
      run_attempt_count: 1
    }

    Enum.each(protected_updates, fn {field, value} ->
      assert {:error, :fanout_structure_immutable} =
               Objectives.update_objective(child, %{field => value})

      assert {:ok, unchanged} = Objectives.get_objective(child.id)
      assert Map.fetch!(unchanged, field) == Map.fetch!(child, field)
    end)

    assert {:ok, transitioned} =
             TerminalTransitions.transition_active_child(
               child,
               %{status: "running", proposer_hint: %{"fanout_child" => %{"version" => 99}}},
               "run_progress",
               %{operation: "immutability_test"}
             )

    assert transitioned.status == "running"
    assert transitioned.proposer_hint == child.proposer_hint
  end

  # ADR 0086 contract-1 ownership proof (v1.0.3 M1, release.v103
  # `v103_pilot_db`): sandbox access is explicit per-test ownership, not
  # VM-ambient. A process OUTSIDE the `$callers` chain — the same shape as
  # the engine's Task.Supervised children behind a long-lived agent — has
  # no access until the test allows it. Under the pre-conversion
  # `async: false` shared mode this test is RED (the unallowed process
  # reads ambiently), which is the recorded red-first proof of why the file
  # previously required the serial `db_serial` lane.
  test "contract-1 ownership proof: out-of-chain processes need an explicit sandbox allowance" do
    parent = self()

    count_objectives = fn ->
      try do
        {:ok, Repo.aggregate(Objective, :count)}
      rescue
        error in DBConnection.OwnershipError -> {:error, error}
      end
    end

    unallowed =
      spawn(fn ->
        receive do
          :go -> send(parent, {:unallowed, count_objectives.()})
        end
      end)

    send(unallowed, :go)
    assert_receive {:unallowed, {:error, %DBConnection.OwnershipError{}}}

    allowed =
      spawn(fn ->
        receive do
          :go -> send(parent, {:allowed, count_objectives.()})
        end
      end)

    allow_sandbox(allowed)
    send(allowed, :go)
    assert_receive {:allowed, {:ok, count}}
    assert is_integer(count)
  end

  defp unique_user(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
