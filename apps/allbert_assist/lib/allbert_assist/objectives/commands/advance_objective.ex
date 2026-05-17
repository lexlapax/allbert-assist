defmodule AllbertAssist.Objectives.Commands.AdvanceObjective do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_advance_objective",
    description: "Private objective step execution and observation command."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.Step
  alias AllbertAssist.Repo

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, step} <- step(params),
         {:ok, _objective} <- Objectives.get_objective(step.objective_id),
         {:ok, execute_patch, execute_result, execute_directives} <-
           Commands.run_subcommand(
             Commands.ExecuteStep,
             %{step_id: step.id, trace_id: trace_id(params, context)},
             context
           ),
         {:ok, executed_step} <- executed_step(execute_result),
         context <- merge_context_state(context, execute_patch),
         {:ok, observe_patch, observe_result, observe_directives} <-
           Commands.run_subcommand(
             Commands.ObserveStep,
             %{step_id: executed_step.id, trace_id: trace_id(params, context)},
             context
           ) do
      state =
        state
        |> Map.merge(Map.drop(execute_patch, [:last_result, :last_command, :last_error]))
        |> Map.merge(Map.drop(observe_patch, [:last_result, :last_command, :last_error]))

      Commands.finish(
        :advance_objective,
        {:ok, Map.put(observe_result, :stage, "advance_objective")},
        state,
        directives: execute_directives ++ observe_directives
      )
    else
      {:error, reason} ->
        Commands.finish(:advance_objective, {:error, reason}, state)
    end
  end

  defp step(params) do
    cond do
      step_id = field(params, :step_id) ->
        get_step(step_id)

      objective_id = field(params, :objective_id) || field(params, :id) ->
        current_step(objective_id)

      true ->
        {:error, :missing_step_id}
    end
  end

  defp current_step(objective_id) when is_binary(objective_id) and objective_id != "" do
    case Objectives.get_objective(objective_id) do
      {:ok, %{current_step_id: step_id}} when is_binary(step_id) and step_id != "" ->
        get_step(step_id)

      {:ok, objective} ->
        objective.id
        |> Objectives.list_steps()
        |> Enum.reverse()
        |> List.first()
        |> case do
          %Step{} = step -> {:ok, step}
          nil -> {:error, :no_current_step}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp current_step(_objective_id), do: {:error, :missing_objective_id}

  defp get_step(id) when is_binary(id) and id != "" do
    case Repo.get(Step, id) do
      %Step{} = step -> {:ok, step}
      nil -> {:error, {:step_not_found, id}}
    end
  end

  defp get_step(_id), do: {:error, :missing_step_id}

  defp executed_step(%{step: %Step{} = step}), do: {:ok, step}
  defp executed_step(_result), do: {:error, :missing_executed_step}

  defp merge_context_state(context, patch) do
    state =
      context
      |> Map.get(:state, %{})
      |> Map.merge(patch)

    Map.put(context, :state, state)
  end

  defp trace_id(params, context) do
    field(params, :trace_id) || field(context, :trace_id)
  end

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
