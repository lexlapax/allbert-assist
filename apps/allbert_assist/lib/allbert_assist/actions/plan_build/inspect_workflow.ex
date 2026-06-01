defmodule AllbertAssist.Actions.PlanBuild.InspectWorkflow do
  @moduledoc "Validate and inspect one workflow YAML file."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :local,
    skill_backed?: false,
    confirmation: :not_required,
    name: "inspect_workflow",
    description: "Validate one workflow YAML file and return diagnostics.",
    category: "plan_build",
    tags: ["plan_build", "workflows", "read_only"],
    schema: [workflow_id: [type: :string, required: true]],
    output_schema: []

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Workflows

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    workflow_id = field(params, :workflow_id)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, workflow} <- Workflows.inspect_workflow(workflow_id) do
      output_data = %{workflow: workflow, diagnostics: []}

      {:ok,
       response(:completed, "Workflow #{workflow_id} is valid.", permission_decision, output_data)}
    else
      false ->
        {:ok,
         response(:denied, permission_decision.reason, permission_decision, %{
           error: :permission_denied
         })}

      {:error, reason} ->
        {:ok,
         response(:error, "Workflow #{workflow_id} is invalid.", permission_decision, %{
           error: reason,
           diagnostics: [reason]
         })}
    end
  end

  defp response(status, message, permission_decision, output_data) do
    %{
      message: message,
      status: status,
      output_data: output_data,
      diagnostics: Map.get(output_data, :diagnostics, []),
      permission_decision: permission_decision,
      actions: [
        %{
          name: "inspect_workflow",
          status: status,
          permission: :read_only,
          permission_decision: permission_decision
        }
        |> Map.merge(output_data)
      ]
    }
  end

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
