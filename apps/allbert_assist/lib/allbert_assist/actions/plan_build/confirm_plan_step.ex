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
      step_id: [type: :string, required: true]
    ],
    output_schema: []

  @impl true
  def run(params, context) do
    PlanBuildRuntime.advance(
      Map.fetch!(params, :objective_id),
      Map.merge(context, %{user_id: user_id(context)})
    )
  end

  defp user_id(context) do
    Map.get(context, :user_id) ||
      Map.get(context, "user_id") ||
      get_in(context, [:request, :user_id]) ||
      get_in(context, ["request", "user_id"]) ||
      Map.get(context, :operator_id) ||
      Map.get(context, :actor)
  end
end
