defmodule AllbertAssist.Objectives.Commands.EvaluateSteps do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_evaluate_steps",
    description: "Private objective acceptance evaluation command."

  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.Evaluator

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, objective} <- objective(params),
         steps <- Objectives.list_steps(objective.id) do
      verdict = Evaluator.evaluate(objective, steps)

      state =
        state
        |> update_nested(:last_acceptance_verdicts, objective.id, verdict)
        |> Map.put(:last_summary, %{
          objective_id: objective.id,
          verdict: verdict,
          evaluated_steps: length(steps)
        })

      Commands.finish(
        :evaluate_steps,
        {:ok,
         %{
           objective: objective,
           steps: steps,
           verdict: verdict,
           evaluated_steps: length(steps),
           stage: "evaluate_steps"
         }},
        state
      )
    else
      {:error, reason} ->
        Commands.finish(:evaluate_steps, {:error, reason}, state)
    end
  end

  defp objective(params) do
    with {:ok, objective_id} <- objective_id(params) do
      Objectives.get_objective(objective_id)
    end
  end

  defp objective_id(params) do
    case field(params, :objective_id) || field(params, :id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
  end

  defp update_nested(state, key, nested_key, value) do
    current = Map.get(state, key, %{})
    Map.put(state, key, Map.put(current, nested_key, value))
  end

  defp field(map, key), do: Maps.field_truthy(map, key)
end
