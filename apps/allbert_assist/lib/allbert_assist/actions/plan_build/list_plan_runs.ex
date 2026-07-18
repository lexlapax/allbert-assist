defmodule AllbertAssist.Actions.PlanBuild.ListPlanRuns do
  @moduledoc "List plan-run objectives."

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :internal,
    execution_mode: :local,
    skill_backed?: false,
    confirmation: :not_required,
    name: "list_plan_runs",
    description: "List active plan runs.",
    category: "plan_build",
    tags: ["plan_build", "objectives", "read_only"],
    schema: [
      status: [type: :string, required: false],
      limit: [type: :integer, required: false],
      format: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: []

  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    permission_decision = PermissionGate.authorize(:read_only, context)
    user_id = field(params, :user_id) || field(context, :user_id) || "local"
    limit = field(params, :limit) || 50
    statuses = field(params, :status)

    plans =
      user_id
      |> Objectives.list_objectives(statuses: statuses, limit: limit)
      |> Enum.filter(&String.starts_with?(&1.source_intent || "", "workflow:"))
      |> Enum.map(&plan_map/1)

    output_data = %{plans: plans, ids: Enum.map(plans, & &1.id)}

    {:ok,
     %{
       message: "Listed #{length(plans)} plan runs.",
       status: :completed,
       output_data: output_data,
       permission_decision: permission_decision,
       actions: [
         %{
           name: "list_plan_runs",
           status: :completed,
           permission: :read_only,
           permission_decision: permission_decision
         }
         |> Map.merge(output_data)
       ]
     }}
  end

  defp plan_map(objective) do
    %{
      id: objective.id,
      title: objective.title,
      status: objective.status,
      source_intent: objective.source_intent,
      current_step_id: objective.current_step_id
    }
  end

  defp field(map, key), do: Maps.field_truthy(map, key)
end
