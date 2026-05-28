defmodule AllbertAssist.Actions.Onboarding.StepComplete do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :internal,
    execution_mode: :objectives_write,
    skill_backed?: false,
    confirmation: :not_required,
    name: "onboarding_step_complete",
    description: "Record progress for one first-run onboarding objective step.",
    category: "onboarding",
    tags: ["onboarding", "objectives", "write"],
    schema: [
      objective_id: [type: :string, required: true],
      step_id: [type: :string, required: true],
      outcome: [type: :string, required: false],
      note: [type: :string, required: false],
      evidence: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      objective: [type: :map, required: false],
      current_step: [type: :map, required: false],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Onboarding
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:objective_write, context)

    with {:allowed, true} <- {:allowed, PermissionGate.allowed?(permission_decision)},
         {:ok, user_id} <- user_id(params, context),
         {:ok, objective_id} <- required(params, :objective_id),
         {:ok, step_id} <- required(params, :step_id),
         {:ok, state} <- Onboarding.complete_step(user_id, objective_id, step_id, params) do
      {:ok, completed(state, permission_decision)}
    else
      {:allowed, false} ->
        {:ok, denied(permission_decision)}

      {:error, reason} ->
        {:ok, error(permission_decision, reason)}
    end
  end

  defp completed(state, permission_decision) do
    %{
      message: "Recorded onboarding step progress.",
      status: :completed,
      permission_decision: permission_decision,
      objective: state.objective,
      steps: state.steps,
      current_step: state.current_step,
      evidence: state.evidence,
      completed_step: state.completed_step,
      actions: [
        action(:completed, permission_decision, %{
          objective_id: state.objective.id,
          step_id: state.completed_step.id,
          outcome: state.completed_step.status
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

  defp error(permission_decision, reason) do
    %{
      message: "Unable to record onboarding step: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: permission_decision,
      actions: [action(:error, permission_decision, %{error: reason})]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "onboarding_step_complete",
      status: status,
      permission: :objective_write,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
  end

  defp user_id(params, context) do
    case field(params, :user_id) || field(context, :user_id) ||
           get_in_field(context, [:request, :user_id]) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, :missing_user_id}
    end
  end

  defp required(params, key) do
    case field(params, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _other -> {:error, {:missing_required, key}}
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

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_value, _key), do: nil
end
