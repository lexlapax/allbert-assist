defmodule AllbertAssist.Actions.PlanBuild.ExpandWorkflow do
  @moduledoc "Expand a validated workflow into objective step attrs."

  use AllbertAssist.Action,
    permission: :workflow_read,
    exposure: :internal,
    execution_mode: :workflow_expand,
    skill_backed?: false,
    confirmation: :not_required,
    name: "expand_workflow",
    description: "Validate and expand a workflow without running it.",
    category: "plan_build",
    tags: ["plan_build", "workflows"],
    schema: [workflow_id: [type: :string, required: true], inputs: [type: :map, required: false]],
    output_schema: []

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Workflows

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:workflow_read, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, expanded} <-
           Workflows.expand(field(params, :workflow_id), field(params, :inputs) || %{}, context) do
      output_data = Map.take(expanded, [:steps, :step_count, :preview, :resolved_inputs])

      {:ok,
       %{
         message: "Expanded workflow #{field(params, :workflow_id)}.",
         status: :completed,
         output_data: output_data,
         permission_decision: permission_decision,
         actions: [action(:completed, permission_decision, output_data)]
       }}
    else
      false -> {:ok, denied(permission_decision)}
      {:error, reason} -> {:ok, error(permission_decision, reason)}
    end
  end

  defp denied(permission_decision),
    do: response(:denied, permission_decision, %{error: :permission_denied})

  defp error(permission_decision, reason),
    do: response(:error, permission_decision, %{error: reason})

  defp response(status, permission_decision, output_data) do
    %{
      message: inspect(Map.get(output_data, :error, status)),
      status: status,
      output_data: output_data,
      permission_decision: permission_decision,
      actions: [action(status, permission_decision, output_data)]
    }
  end

  defp action(status, permission_decision, metadata),
    do:
      %{
        name: "expand_workflow",
        status: status,
        permission: :workflow_read,
        permission_decision: permission_decision
      }
      |> Map.merge(metadata)

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
