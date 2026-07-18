defmodule AllbertAssist.Objectives.Commands.ContinueObjective do
  @moduledoc false

  use Jido.Action,
    name: "allbert_objectives_continue_objective",
    description: "Private objective continuation command."

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Commands
  alias AllbertAssist.Objectives.Step
  alias AllbertAssist.Repo

  @impl true
  def run(params, context) do
    state = Map.get(context, :state, %{})

    with {:ok, objective} <- objective(params, context),
         {:ok, result} <- continue(objective, params, context) do
      Commands.finish(
        :continue_objective,
        {:ok, Map.put(result, :stage, "continue_objective")},
        state
      )
    else
      {:error, reason} ->
        Commands.finish(:continue_objective, {:error, reason}, state)
    end
  end

  defp continue(%{status: "abandoned"} = objective, _params, _context) do
    {:ok,
     %{
       status: :objective_abandoned,
       objective: objective,
       reason: "Objective is abandoned."
     }}
  end

  defp continue(%{status: "cancelled"} = objective, _params, _context) do
    {:ok,
     %{
       status: :objective_cancelled,
       objective: objective,
       reason: "Objective is cancelled."
     }}
  end

  defp continue(%{status: "completed"} = objective, _params, _context) do
    {:ok,
     %{
       status: :completed,
       objective: objective,
       reason: "Objective is already completed."
     }}
  end

  defp continue(%{status: "failed"} = objective, _params, _context) do
    {:ok,
     %{
       status: :objective_failed,
       objective: objective,
       reason: "Objective has failed."
     }}
  end

  defp continue(objective, params, context) do
    with {:ok, step} <- current_step(objective),
         :ok <- step_ready(step) do
      case advance_step(step, params, context) do
        {:ok,
         %{objective: %{status: "completed"} = completed, step: advanced_step, verdict: :met}} ->
          {:ok, completed_response(completed, advanced_step)}

        {:ok, %{objective: next_objective, verdict: :needs_more_steps}} ->
          continue_with_hint(next_objective, params, context)

        {:ok, %{objective: next_objective}} ->
          {:ok, still_blocked(next_objective, "Objective needs operator review.")}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, {:confirmation_pending, id}} ->
        {:ok, still_blocked(objective, "Confirmation #{id} is still pending.")}

      {:error, :no_current_step} ->
        continue_with_hint(objective, params, context)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp continue_with_hint(objective, params, context) do
    proposer_params = %{
      objective_id: objective.id,
      text: objective.source_intent || objective.objective,
      trace_id: trace_id(params, context)
    }

    with {:ok, propose_patch, proposed, _directives} <-
           Commands.run_subcommand(Commands.ProposeSteps, proposer_params, context) do
      case proposed do
        %{steps: [step | _rest]} ->
          context = merge_context_state(context, propose_patch)
          authorize_step(objective, step, proposed, params, context)

        %{objective: %{status: "blocked"} = blocked, impasse: impasse} ->
          {:ok, still_blocked(blocked, "Objective is blocked by #{impasse}.")}

        _other ->
          {:ok, still_blocked(objective, "No new objective steps were proposed.")}
      end
    end
  end

  defp authorize_step(_objective, step, proposed, params, context) do
    authorize_params = %{step_id: step.id, trace_id: trace_id(params, context)}

    with {:ok, _patch, %{objective: updated, step: authorized, response: response}, _directives} <-
           Commands.run_subcommand(Commands.AuthorizeStep, authorize_params, context) do
      {:ok,
       %{
         message: "Objective #{updated.id} advanced to step #{authorized.id}.",
         status: Map.get(response, :status, :completed),
         objective: updated,
         step: authorized,
         response: response,
         continuation: Map.get(proposed, :continuation),
         confirmation_id: Map.get(response, :confirmation_id)
       }}
    end
  end

  defp advance_step(step, params, context) do
    advance_params = %{step_id: step.id, trace_id: trace_id(params, context)}

    with {:ok, _patch, result, _directives} <-
           Commands.run_subcommand(Commands.AdvanceObjective, advance_params, context) do
      {:ok, result}
    end
  end

  defp current_step(objective) do
    if is_binary(objective.current_step_id) do
      case Repo.get(Step, objective.current_step_id) do
        %Step{} = step -> {:ok, step}
        nil -> {:error, :no_current_step}
      end
    else
      objective.id
      |> Objectives.list_steps()
      |> Enum.reverse()
      |> List.first()
      |> case do
        %Step{} = step -> {:ok, step}
        nil -> {:error, :no_current_step}
      end
    end
  end

  defp step_ready(%Step{confirmation_id: id}) when is_binary(id) and id != "" do
    case Confirmations.read(id) do
      {:ok, %{"status" => "approved"}} -> :ok
      {:ok, %{"status" => "pending"}} -> {:error, {:confirmation_pending, id}}
      {:ok, %{"status" => status}} -> {:error, {:confirmation_not_approved, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp step_ready(%Step{status: "blocked"}), do: {:error, :blocked_without_confirmation}
  defp step_ready(_step), do: :ok

  defp objective(params, context) do
    with {:ok, objective_id} <- objective_id(params),
         user_id <- user_id(params, context) do
      case user_id do
        value when is_binary(value) and value != "" ->
          Objectives.get_objective(value, objective_id)

        _other ->
          Objectives.get_objective(objective_id)
      end
    end
  end

  defp objective_id(params) do
    case field(params, :objective_id) || field(params, :id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
  end

  defp user_id(params, context) do
    field(params, :user_id) || field(context, :user_id) ||
      get_in_field(context, [:request, :user_id])
  end

  defp completed_response(objective, step) do
    %{
      message: "Objective #{objective.id} completed.",
      status: :completed,
      objective: objective,
      step: step
    }
  end

  defp still_blocked(objective, reason) do
    %{
      message: "Objective #{objective.id} is still blocked: #{reason}",
      status: :still_blocked,
      reason: reason,
      objective: objective
    }
  end

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

  defp get_in_field(value, keys) do
    Enum.reduce_while(keys, value, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp field(%_struct{} = struct, key), do: Map.get(struct, key)

  defp field(map, key) when is_map(map), do: Maps.field_truthy(map, key)

  defp field(_value, _key), do: nil
end
