defmodule AllbertAssist.Objectives.ObjectiveTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AcceptanceCriteria
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Repo

  @fixtures Path.expand("../../fixtures/v0.24/acceptance_criteria", __DIR__)

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
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               source_thread_id: "thr_a",
               active_app: "stocksage",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               acceptance_criteria: AcceptanceCriteria.single_step()
             })

    assert objective.status == "open"
    assert objective.loop_count == 0
    assert {:ok, ^objective} = Objectives.get_objective("alice", objective.id)
    assert {:error, :not_found} = Objectives.get_objective("bob", objective.id)

    assert [listed] = Objectives.list_objectives("alice", active_app: "stocksage")
    assert listed.id == objective.id
    assert [] = Objectives.list_objectives("bob")

    stale = DateTime.add(DateTime.utc_now(), -2, :hour)

    assert {1, _} =
             Objective
             |> where([objective], objective.id == ^objective.id)
             |> Repo.update_all(set: [updated_at: stale])

    assert {:ok, 1} = Objectives.abandon_stale_objectives(now: DateTime.utc_now())
    assert {:ok, abandoned} = Objectives.get_objective(objective.id)
    assert abandoned.status == "abandoned"
  end
end
