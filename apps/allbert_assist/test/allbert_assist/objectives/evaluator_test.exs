defmodule AllbertAssist.Objectives.EvaluatorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AcceptanceCriteria
  alias AllbertAssist.Objectives.Evaluator

  test "evaluates single-step RunAnalysis criteria deterministically" do
    criteria =
      AcceptanceCriteria.single_step()
      |> put_in(["required", Access.at(0), "params_match"], %{"ticker" => "AAPL"})

    assert :needs_more_steps = Evaluator.evaluate(criteria, [])

    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               acceptance_criteria: criteria
             })

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "completed",
               stage: "observe_step",
               candidate_action: "StockSage.Actions.RunAnalysis",
               action_params: %{"ticker" => "AAPL"}
             })

    assert :met = Evaluator.evaluate(objective, [step])
  end

  test "observation_contains checks completed step observations without regex" do
    criteria = %{
      "min_completed_steps" => 1,
      "required" => [
        %{"kind" => "observation_contains", "substring" => "comparison complete"}
      ],
      "needs_more_when" => [%{"kind" => "completed_step_count_below", "value" => 1}]
    }

    assert :not_met =
             Evaluator.evaluate(criteria, [
               %{status: "completed", observation_summary: "different text"}
             ])

    assert :met =
             Evaluator.evaluate(criteria, [
               %{status: "completed", observation_summary: "Comparison complete for AAPL/MSFT"}
             ])
  end
end
