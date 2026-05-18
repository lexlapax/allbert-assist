defmodule AllbertAssist.Actions.Objectives.ReadActionsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives

  test "list_objectives is user scoped and goes through action runner metadata" do
    user = unique_user("read_actions")
    other_user = unique_user("read_actions_other")

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: user,
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               active_app: "stocksage"
             })

    assert {:ok, _bob} =
             Objectives.create_objective(%{
               user_id: other_user,
               title: "Analyze MSFT",
               objective: "Complete one analysis for MSFT."
             })

    assert {:ok, response} = Runner.run("list_objectives", %{user_id: user}, %{})

    assert response.status == :completed
    assert [%{id: id, title: "Analyze AAPL"}] = response.objectives
    assert id == objective.id
    assert response.runner_metadata.action_capability.permission == :read_only
  end

  test "show_objective returns details and rejects cross-user reads" do
    user = unique_user("show_objective")
    other_user = unique_user("show_objective_other")

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: user,
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
             Runner.run("show_objective", %{id: objective.id, user_id: user}, %{})

    assert response.status == :completed
    assert response.objective.id == objective.id
    assert [%{id: step_id, action_params: %{"ticker" => "AAPL"}}] = response.steps
    assert step_id == step.id
    assert [%{kind: "step_proposed"}] = response.events

    assert {:ok, missing} =
             Runner.run("show_objective", %{id: objective.id, user_id: other_user}, %{})

    assert missing.status == :not_found
  end

  test "objective actions require user context at the action boundary" do
    assert {:ok, response} = Runner.run("list_objectives", %{}, %{})

    assert response.status == :error
    assert response.error == :missing_user_id
  end

  test "cancel_objective transitions objective and pending steps cooperatively" do
    user = unique_user("cancel_objective")

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: user,
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
               %{id: objective.id, user_id: user, reason: "operator changed plan"},
               %{user_id: user, operator_id: user, actor: user}
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

  test "continue_objective returns advisory statuses for pending and terminal objectives" do
    user = unique_user("continue_objective")
    confirmation_id = unique_id("conf_continue_pending")

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: user,
               title: "Blocked objective",
               objective: "Wait for approval.",
               status: "blocked"
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "blocked",
               stage: "authorize_step",
               candidate_action: "StockSage.Actions.RunAnalysis",
               confirmation_id: confirmation_id
             })

    assert {:ok, _objective} = Objectives.update_objective(objective, %{current_step_id: step.id})

    assert {:ok, _confirmation} =
             Confirmations.create(%{
               id: confirmation_id,
               origin: %{actor: user, channel: "test", surface: "objective-action-test"},
               target_action: %{name: "run_analysis"},
               target_permission: :stocksage_analyze,
               target_execution_mode: :external_market_data,
               security_decision: %{
                 permission: :stocksage_analyze,
                 decision: :needs_confirmation
               },
               params_summary: %{objective_id: objective.id, step_id: step.id}
             })

    assert {:ok, blocked} =
             Runner.run("continue_objective", %{id: objective.id, user_id: user}, %{
               user_id: user,
               operator_id: user,
               actor: user
             })

    assert blocked.status == :still_blocked
    assert blocked.reason =~ "Confirmation #{confirmation_id} is still pending"

    assert {:ok, abandoned} =
             Objectives.create_objective(%{
               user_id: user,
               title: "Abandoned objective",
               objective: "Already abandoned.",
               status: "abandoned"
             })

    assert {:ok, terminal} =
             Runner.run("continue_objective", %{id: abandoned.id, user_id: user}, %{
               user_id: user,
               operator_id: user,
               actor: user
             })

    assert terminal.status == :objective_abandoned

    assert {:ok, missing} =
             Runner.run("continue_objective", %{id: "obj_missing", user_id: user}, %{
               user_id: user,
               operator_id: user,
               actor: user
             })

    assert missing.status == :not_found
  end

  defp unique_user(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end

  defp unique_id(prefix) do
    "#{prefix}_#{System.unique_integer([:positive])}"
  end
end
