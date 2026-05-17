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

  test "verdict matrix covers needs-more, not-met, and unknown clauses" do
    needs_more = %{
      "min_completed_steps" => 2,
      "required" => [],
      "needs_more_when" => [%{"kind" => "completed_step_count_below", "value" => 2}]
    }

    assert :needs_more_steps =
             Evaluator.evaluate(needs_more, [
               %{status: "completed", candidate_action: "one"}
             ])

    not_met = %{
      "min_completed_steps" => 1,
      "required" => [%{"kind" => "step_completed_with_action", "action" => "missing"}],
      "needs_more_when" => []
    }

    assert :not_met =
             Evaluator.evaluate(not_met, [
               %{status: "completed", candidate_action: "other"}
             ])

    unknown = %{
      "min_completed_steps" => 1,
      "required" => [%{"kind" => "future_clause"}],
      "needs_more_when" => []
    }

    assert :not_met =
             Evaluator.evaluate(unknown, [
               %{status: "completed", candidate_action: "other"}
             ])
  end
end
