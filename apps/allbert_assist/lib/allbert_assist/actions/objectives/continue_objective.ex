defmodule AllbertAssist.Actions.Objectives.ContinueObjective do
  @moduledoc "Advance a blocked objective when its blocker has changed."

  use Jido.Action,
    name: "continue_objective",
    description: "Continue a durable objective after approval or operator intervention.",
    category: "objectives",
    tags: ["objectives", "write"],
    schema: [
      id: [type: :string, required: false],
      objective_id: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Objectives.Step
  alias AllbertAssist.Repo
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:objective_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- user_id(params, context),
         {:ok, objective_id} <- objective_id(params),
         {:ok, objective} <- Objectives.get_objective(user_id, objective_id) do
      continue(objective, permission_decision, context)
    else
      {:allowed, false} ->
        {:ok, denied(permission_decision)}

      {:error, :not_found} ->
        {:ok, not_found(permission_decision)}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp continue(%{status: "abandoned"}, _permission_decision, _context),
    do: {:error, :objective_abandoned}

  defp continue(%{status: "cancelled"}, _permission_decision, _context),
    do: {:error, :objective_cancelled}

  defp continue(objective, permission_decision, context) do
    with {:ok, step} <- current_step(objective),
         :ok <- step_ready(step) do
      case advance_step(objective, step, context) do
        {:ok, %{objective: %{status: "completed"} = completed, verdict: :met}} ->
          {:ok, completed_response(completed, step, permission_decision)}

        {:ok, %{objective: next_objective, verdict: :needs_more_steps}} ->
          continue_with_hint(next_objective, permission_decision, context)

        {:ok, %{objective: next_objective}} ->
          {:ok,
           still_blocked(next_objective, permission_decision, "Objective needs operator review.")}

        {:error, reason} ->
          {:ok, error(permission_decision, reason)}
      end
    else
      {:error, {:confirmation_pending, id}} ->
        {:ok,
         still_blocked(objective, permission_decision, "Confirmation #{id} is still pending.")}

      {:error, :no_current_step} ->
        continue_with_hint(objective, permission_decision, context)

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp continue_with_hint(objective, permission_decision, context) do
    case EngineAgent.propose_steps(%{
           objective_id: objective.id,
           text: objective.source_intent || objective.objective,
           trace_id: Map.get(context, :trace_id)
         }) do
      {:ok, %{steps: [step | _rest]} = proposed} ->
        case EngineAgent.authorize_step(%{
               step_id: step.id,
               trace_id: Map.get(context, :trace_id)
             }) do
          {:ok, %{objective: updated, step: authorized, response: response}} ->
            {:ok,
             %{
               message: "Objective #{updated.id} advanced to step #{authorized.id}.",
               status: Map.get(response, :status, :completed),
               objective: objective_map(updated),
               step: step_map(authorized),
               continuation: Map.get(proposed, :continuation),
               confirmation_id: Map.get(response, :confirmation_id),
               permission_decision: permission_decision,
               actions: [
                 action(:completed, permission_decision, %{
                   objective_id: updated.id,
                   step_id: authorized.id,
                   confirmation_id: Map.get(response, :confirmation_id)
                 })
               ]
             }}

          {:error, reason} ->
            {:ok, error(permission_decision, reason)}
        end

      {:ok, %{objective: %{status: "blocked"} = blocked, impasse: impasse}} ->
        {:ok, still_blocked(blocked, permission_decision, "Objective is blocked by #{impasse}.")}

      {:ok, _other} ->
        {:ok,
         still_blocked(objective, permission_decision, "No new objective steps were proposed.")}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp advance_step(_objective, step, context) do
    with {:ok, %{step: executed}} <-
           EngineAgent.execute_step(%{step_id: step.id, trace_id: Map.get(context, :trace_id)}),
         {:ok, observed} <-
           EngineAgent.observe_step(%{
             step_id: executed.id,
             trace_id: Map.get(context, :trace_id)
           }) do
      {:ok, observed}
    else
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected_continue_result, other}}
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

  defp step_ready(%Step{status: "completed"}), do: :ok
  defp step_ready(%Step{status: "blocked"}), do: {:error, :blocked_without_confirmation}
  defp step_ready(_step), do: :ok

  defp completed_response(objective, step, permission_decision) do
    %{
      message: "Objective #{objective.id} completed.",
      status: :completed,
      objective: objective_map(objective),
      step: step_map(step),
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{objective_id: objective.id, step_id: step.id})
      ]
    }
  end

  defp still_blocked(objective, permission_decision, reason) do
    %{
      message: "Objective #{objective.id} is still blocked: #{reason}",
      status: :still_blocked,
      reason: reason,
      objective: objective_map(objective),
      permission_decision: permission_decision,
      actions: [
        action(:still_blocked, permission_decision, %{objective_id: objective.id, reason: reason})
      ]
    }
  end

  defp denied(permission_decision) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      permission_decision: permission_decision,
      actions: [action(:denied, permission_decision, %{error: :permission_denied})]
    }
  end

  defp not_found(permission_decision) do
    %{
      message: "Objective not found.",
      status: :not_found,
      error: :not_found,
      permission_decision: permission_decision,
      actions: [action(:not_found, permission_decision, %{error: :not_found})]
    }
  end

  defp error(permission_decision, reason) do
    %{
      message: "Unable to continue objective: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:error, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "continue_objective",
      status: status,
      permission: :objective_write,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
  end

  defp objective_map(objective) do
    %{
      id: objective.id,
      user_id: objective.user_id,
      title: objective.title,
      status: objective.status,
      current_step_id: objective.current_step_id,
      loop_count: objective.loop_count,
      progress_summary: objective.progress_summary
    }
  end

  defp step_map(step) do
    %{
      id: step.id,
      status: step.status,
      kind: step.kind,
      candidate_action: step.candidate_action,
      parent_step_id: step.parent_step_id,
      confirmation_id: step.confirmation_id
    }
  end

  defp user_id(params, context) do
    case field(params, :user_id) || field(context, :user_id) ||
           get_in_field(context, [:request, :user_id]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp objective_id(params) do
    case field(params, :objective_id) || field(params, :id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
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

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
