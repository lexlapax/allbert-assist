defmodule AllbertAssist.Actions.Objectives.SteerObjectiveRun do
  @moduledoc "Apply an operator steering directive to an owned active objective run."

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :agent,
    execution_mode: :objective_engine,
    skill_backed?: false,
    confirmation: :not_required,
    name: "steer_objective_run",
    description: "Steer an owned objective at its next lifecycle boundary.",
    category: "objectives",
    tags: ["objectives", "steer"],
    schema: [
      objective_id: [type: :string, required: true],
      directive: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives.Steering
  alias AllbertAssist.Security.PermissionGate

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:objective_write, context)

    with true <- PermissionGate.allowed?(decision),
         {:ok, result} <-
           Steering.steer(
             Maps.field(context, :user_id) || Maps.field(params, :user_id),
             Maps.field(params, :objective_id),
             Maps.field(params, :directive)
           ) do
      {:ok, %{message: "Steering queued for #{result.objective.id}.", status: :steered}}
    else
      false ->
        {:ok, %{message: decision.reason, status: :denied}}

      {:error, reason} ->
        {:ok, %{message: "Unable to steer objective: #{inspect(reason)}", status: :error}}
    end
  end
end
