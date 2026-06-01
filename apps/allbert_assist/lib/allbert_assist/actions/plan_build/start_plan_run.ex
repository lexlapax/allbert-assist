defmodule AllbertAssist.Actions.PlanBuild.StartPlanRun do
  @moduledoc "Confirm and start a Plan/Build workflow run."

  use AllbertAssist.Action,
    permission: :workflow_run_start,
    exposure: :internal,
    execution_mode: :plan_run_start,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "start_plan_run",
    description: "Start a workflow plan run after operator approval.",
    category: "plan_build",
    tags: ["plan_build", "workflows", "confirmation"],
    schema: [
      workflow_id: [type: :string, required: true],
      inputs: [type: :map, required: false],
      title: [type: :string, required: false],
      parent_objective_id: [type: :string, required: false],
      user_id: [type: :string, required: false]
    ],
    output_schema: []

  @impl true
  def run(params, context), do: AllbertAssist.PlanBuild.start_plan_run(params, context)
end
