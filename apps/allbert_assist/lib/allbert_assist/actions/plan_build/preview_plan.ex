defmodule AllbertAssist.Actions.PlanBuild.PreviewPlan do
  @moduledoc "Emit an advisory Plan Preview Contract packet."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :plan_preview,
    skill_backed?: false,
    confirmation: :not_required,
    name: "preview_plan",
    description: "Preview a workflow plan without granting authority.",
    category: "plan_build",
    tags: ["plan_build", "preview"],
    schema: [
      workflow_id: [type: :string, required: false],
      plan_text: [type: :string, required: false],
      inputs: [type: :map, required: false],
      format: [type: :string, required: false]
    ],
    output_schema: []

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Workflows

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    workflow_id = field(params, :workflow_id)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, expanded} when is_binary(workflow_id) <-
           Workflows.preview(workflow_id, field(params, :inputs) || %{}, context) do
      output_data = %{preview: expanded.preview}

      {:ok,
       %{
         message: "Previewed workflow #{workflow_id}.",
         status: :advisory,
         output_data: output_data,
         permission_decision: permission_decision,
         actions: [action(:advisory, permission_decision, output_data)]
       }}
    else
      false -> {:ok, response(:denied, permission_decision, %{error: :permission_denied})}
      {:error, reason} -> {:ok, response(:error, permission_decision, %{error: reason})}
      _other -> {:ok, response(:error, permission_decision, %{error: :missing_workflow_id})}
    end
  end

  defp response(status, permission_decision, output_data),
    do: %{
      message: inspect(Map.get(output_data, :error, status)),
      status: status,
      output_data: output_data,
      permission_decision: permission_decision,
      actions: [action(status, permission_decision, output_data)]
    }

  defp action(status, permission_decision, metadata),
    do:
      %{
        name: "preview_plan",
        status: status,
        permission: :read_only,
        permission_decision: permission_decision
      }
      |> Map.merge(metadata)

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
