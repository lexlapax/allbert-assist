defmodule AllbertAssist.Actions.PlanBuild.CancelPlanRun do
  @moduledoc "Cancel a Plan/Build objective run cooperatively."

  use AllbertAssist.Action,
    permission: :plan_cancel,
    exposure: :internal,
    execution_mode: :plan_cancel,
    skill_backed?: false,
    confirmation: :not_required,
    name: "cancel_plan_run",
    description: "Cancel a plan run objective.",
    category: "plan_build",
    tags: ["plan_build", "cancel"],
    schema: [
      objective_id: [type: :string, required: true],
      reason: [type: :string, required: true],
      user_id: [type: :string, required: false]
    ],
    output_schema: []

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Maps

  @impl true
  def run(params, context) do
    with {:ok, response} <- Runner.run("cancel_objective", params, context) do
      {:ok,
       Map.put(response, :output_data, %{
         objective_id: field(params, :objective_id),
         cancelled?: response.status == :cancelled
       })}
    end
  end

  defp field(map, key), do: Maps.field_truthy(map, key)
end
