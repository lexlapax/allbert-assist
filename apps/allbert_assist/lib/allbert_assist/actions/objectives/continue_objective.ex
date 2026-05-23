defmodule AllbertAssist.Actions.Objectives.ContinueObjective do
  @moduledoc "Advance a blocked objective when its blocker has changed."

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :internal,
    execution_mode: :objective_engine,
    skill_backed?: false,
    confirmation: :not_required,
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

  alias AllbertAssist.Objectives
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:objective_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- user_id(params, context),
         {:ok, objective_id} <- objective_id(params),
         {:ok, result} <- Objectives.continue(user_id, objective_id) do
      {:ok, response(result, permission_decision)}
    else
      {:allowed, false} ->
        {:ok, denied(permission_decision)}

      {:error, :not_found} ->
        {:ok, not_found(permission_decision)}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp response(%{status: :completed, objective: objective, step: step}, permission_decision) do
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

  defp response(%{status: :completed, objective: objective, reason: reason}, permission_decision) do
    %{
      message: "Objective #{objective.id} cannot continue: #{reason}",
      status: :completed,
      reason: reason,
      objective: objective_map(objective),
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{objective_id: objective.id, reason: reason})
      ]
    }
  end

  defp response(
         %{status: :still_blocked, objective: objective, reason: reason},
         permission_decision
       ) do
    still_blocked(objective, permission_decision, reason)
  end

  defp response(%{status: status, objective: objective, reason: reason}, permission_decision)
       when status in [:objective_abandoned, :objective_cancelled, :objective_failed] do
    %{
      message: "Objective #{objective.id} cannot continue: #{reason}",
      status: status,
      reason: reason,
      objective: objective_map(objective),
      permission_decision: permission_decision,
      actions: [
        action(status, permission_decision, %{objective_id: objective.id, reason: reason})
      ]
    }
  end

  defp response(%{objective: objective, step: step} = result, permission_decision) do
    status = Map.get(result, :status, :completed)

    %{
      message:
        Map.get(result, :message, "Objective #{objective.id} advanced to step #{step.id}."),
      status: status,
      objective: objective_map(objective),
      step: step_map(step),
      continuation: Map.get(result, :continuation),
      confirmation_id: Map.get(result, :confirmation_id),
      permission_decision: permission_decision,
      actions: [
        action(status, permission_decision, %{
          objective_id: objective.id,
          step_id: step.id,
          confirmation_id: Map.get(result, :confirmation_id)
        })
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
