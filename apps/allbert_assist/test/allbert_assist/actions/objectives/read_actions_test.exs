defmodule AllbertAssist.Actions.Objectives.ReadActionsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives

  test "list_objectives is user scoped and goes through action runner metadata" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               active_app: "stocksage"
             })

    assert {:ok, _bob} =
             Objectives.create_objective(%{
               user_id: "bob",
               title: "Analyze MSFT",
               objective: "Complete one analysis for MSFT."
             })

    assert {:ok, response} = Runner.run("list_objectives", %{user_id: "alice"}, %{})

    assert response.status == :completed
    assert [%{id: id, title: "Analyze AAPL"}] = response.objectives
    assert id == objective.id
    assert response.runner_metadata.action_capability.permission == :read_only
  end

  test "show_objective returns details and rejects cross-user reads" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               active_app: "stocksage"
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "proposed",
               stage: "propose_steps",
               candidate_action: "StockSage.Actions.RunAnalysis",
               action_params: %{ticker: "AAPL"}
             })

    assert {:ok, _event} =
             Objectives.create_event(%{
               objective_id: objective.id,
               step_id: step.id,
               kind: "step_proposed",
               summary: "Proposed step."
             })

    assert {:ok, response} =
             Runner.run("show_objective", %{id: objective.id, user_id: "alice"}, %{})

    assert response.status == :completed
    assert response.objective.id == objective.id
    assert [%{id: step_id, action_params: %{"ticker" => "AAPL"}}] = response.steps
    assert step_id == step.id
    assert [%{kind: "step_proposed"}] = response.events

    assert {:ok, missing} =
             Runner.run("show_objective", %{id: objective.id, user_id: "bob"}, %{})

    assert missing.status == :not_found
  end

  test "objective actions require user context at the action boundary" do
    assert {:ok, response} = Runner.run("list_objectives", %{}, %{})

    assert response.status == :error
    assert response.error == :missing_user_id
  end

  test "cancel_objective transitions objective and pending steps cooperatively" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               status: "blocked"
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "blocked",
               stage: "authorize_step",
               candidate_action: "StockSage.Actions.RunAnalysis",
               confirmation_id: "conf_pending"
             })

    assert {:ok, response} =
             Runner.run(
               "cancel_objective",
               %{id: objective.id, user_id: "alice", reason: "operator changed plan"},
               %{user_id: "alice", operator_id: "alice", actor: "alice"}
             )

    assert response.status == :cancelled
    assert response.objective.status == "cancelled"
    assert response.cancelled_step_count == 1

    assert {:ok, cancelled} = Objectives.get_objective(objective.id)
    assert cancelled.status == "cancelled"
    assert cancelled.progress_summary =~ "operator changed plan"

    assert [cancelled_step] = Objectives.list_steps(objective.id)
    assert cancelled_step.id == step.id
    assert cancelled_step.status == "cancelled"

    assert Enum.any?(Objectives.list_events(objective.id), &(&1.kind == "cancelled"))
  end
end
