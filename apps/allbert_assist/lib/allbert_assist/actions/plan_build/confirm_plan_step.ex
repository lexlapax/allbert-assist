defmodule AllbertAssist.Actions.PlanBuild.ConfirmPlanStep do
  @moduledoc "Internal confirmation target for Plan/Build step checkpoints."

  alias AllbertAssist.PlanBuild.Runtime, as: PlanBuildRuntime

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :internal,
    execution_mode: :plan_step_confirm,
    skill_backed?: false,
    confirmation: :not_required,
    resumable?: true,
    name: "plan_step_confirm",
    description: "Resume a Plan/Build run after a step-level operator confirmation.",
    category: "plan_build",
    tags: ["plan_build", "confirmation", "internal"],
    schema: [
      objective_id: [type: :string, required: true],
      step_id: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: []

  @impl true
  def run(params, context) do
    PlanBuildRuntime.advance(
      Map.get(params, :objective_id) || Map.get(params, "objective_id"),
      Map.merge(context, %{user_id: Map.get(params, :user_id) || Map.get(params, "user_id")})
    )
  end
end
