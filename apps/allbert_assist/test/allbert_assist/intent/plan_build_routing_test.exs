defmodule AllbertAssist.Intent.PlanBuildRoutingTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Agents.IntentAgent
  alias AllbertAssist.Objectives

  test "routes objective-backed Plan/Build corpus phrases through IntentAgent" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Workflow run",
               objective: "Run workflow.",
               status: "running",
               active_app: "allbert",
               source_intent: "workflow:multi_step:1"
             })

    assert {:ok, list_response} =
             IntentAgent.respond(%{
               text: "list plans",
               channel: :test,
               user_id: "local",
               operator_id: "local",
               input_signal_id: "sig-list-plans"
             })

    assert list_response.status == :completed
    assert list_response.decision.selected_action == "list_plan_runs"

    assert {:ok, show_response} =
             IntentAgent.respond(%{
               text: "show plan #{objective.id}",
               channel: :test,
               user_id: "local",
               operator_id: "local",
               input_signal_id: "sig-show-plan"
             })

    assert show_response.status == :completed
    assert show_response.decision.selected_action == "show_objective"

    assert {:ok, cancel_response} =
             IntentAgent.respond(%{
               text: "cancel plan #{objective.id}",
               channel: :test,
               user_id: "local",
               operator_id: "local",
               input_signal_id: "sig-cancel-plan"
             })

    assert cancel_response.status == :cancelled
    assert cancel_response.decision.selected_action == "cancel_plan_run"
  end
end
