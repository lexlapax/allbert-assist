defmodule AllbertAssist.Actions.PlanBuild.ListWorkflows do
  @moduledoc "List operator-authored workflow YAML files."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :local,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_workflows",
    description: "List workflow YAML files under Allbert Home.",
    category: "plan_build",
    tags: ["plan_build", "workflows", "read_only"],
    schema: [],
    output_schema: []

  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Workflows

  @impl true
  def run(_params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)

    with true <- PermissionGate.allowed?(permission_decision),
         {:ok, workflows, diagnostics} <- Workflows.list() do
      output_data = %{workflows: workflows, diagnostics: diagnostics}

      {:ok,
       %{
         message: "Listed #{length(workflows)} workflows.",
         status: :completed,
         output_data: output_data,
         diagnostics: diagnostics,
         permission_decision: permission_decision,
         actions: [action(:completed, permission_decision, output_data)]
       }}
    else
      false -> {:ok, denied(permission_decision)}
    end
  end

  defp denied(permission_decision),
    do: response(:denied, permission_decision, %{error: :permission_denied})

  defp response(status, permission_decision, output_data) do
    %{
      message: inspect(Map.get(output_data, :error, status)),
      status: status,
      output_data: output_data,
      permission_decision: permission_decision,
      actions: [action(status, permission_decision, output_data)]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "list_workflows",
      status: status,
      permission: :read_only,
      permission_decision: permission_decision
    }
    |> Map.merge(metadata)
  end
end
