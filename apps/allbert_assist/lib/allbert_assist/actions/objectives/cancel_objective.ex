defmodule AllbertAssist.Actions.Objectives.CancelObjective do
  @moduledoc "Cooperatively cancel a durable objective."

  use AllbertAssist.Action,
    permission: :objective_write,
    # v0.54 M10: agent-routable. confirmation stays :not_required because the plan
    # engine (cancel_plan_run) calls this internally and needs immediate cancel; a
    # cooperative objective cancel is low-risk (Risk tier matches plan_cancel).
    exposure: :agent,
    execution_mode: :objective_engine,
    skill_backed?: false,
    confirmation: :not_required,
    name: "cancel_objective",
    description: "Cancel a durable objective without revoking in-flight confirmations.",
    category: "objectives",
    tags: ["objectives", "write"],
    schema: [
      id: [type: :string, required: false],
      objective_id: [type: :string, required: false],
      user_id: [type: :string, required: false],
      reason: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives.Engine.Agent, as: EngineAgent
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:objective_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- user_id(params, context),
         {:ok, objective_id} <- objective_id(params),
         {:ok, reason} <- reason(params),
         {:ok, result} <-
           EngineAgent.cancel_objective(%{
             id: objective_id,
             user_id: user_id,
             reason: reason,
             trace_id: field(context, :trace_id)
           }) do
      {:ok, cancelled_response(result, permission_decision)}
    else
      {:allowed, false} ->
        {:ok, denied(permission_decision)}

      {:error, :not_found} ->
        {:ok, not_found(permission_decision)}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp cancelled_response(%{objective: objective, reason: reason} = result, permission_decision) do
    %{
      message: "Objective #{objective.id} cancelled: #{reason}",
      status: :cancelled,
      objective: objective_map(objective),
      cancelled_step_count: cancelled_step_count(Map.get(result, :steps, [])),
      permission_decision: permission_decision,
      actions: [
        action(:cancelled, permission_decision, %{
          objective_id: objective.id,
          reason: reason
        })
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
      message: "Unable to cancel objective: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:error, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "cancel_objective",
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

  defp cancelled_step_count(steps) do
    Enum.count(List.wrap(steps), &(Map.get(&1, :status) == "cancelled"))
  end

  defp objective_id(params) do
    case field(params, :id) || field(params, :objective_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_objective_id}
    end
  end

  defp user_id(params, context) do
    case field(context, :user_id) || field(params, :user_id) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp reason(params) do
    case field(params, :reason) do
      value when is_binary(value) ->
        value
        |> String.trim()
        |> case do
          "" -> {:error, :missing_reason}
          reason -> {:ok, reason}
        end

      _other ->
        {:error, :missing_reason}
    end
  end

  defp field(map, key, default \\ nil), do: Maps.field(map, key, default)
end
