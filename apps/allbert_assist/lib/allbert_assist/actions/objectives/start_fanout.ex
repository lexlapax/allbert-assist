defmodule AllbertAssist.Actions.Objectives.StartFanout do
  @moduledoc "Start an acknowledged fan-out after an optional durable confirmation."

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :internal,
    execution_mode: :objective_engine,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "start_fanout",
    description: "Start one delivered, identity-owned fan-out queue.",
    category: "objectives",
    tags: ["objectives", "fanout", "confirmation"],
    schema: [
      parent_id: [type: :string, required: true],
      user_id: [type: :string, required: true]
    ],
    output_schema: []

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Runs.Scheduler

  @impl true
  def run(%{parent_id: parent_id, user_id: user_id}, context) do
    with true <- approved?(context),
         {:ok,
          %{fanout_role: "parent", user_id: ^user_id, kickoff_delivery_state: "acknowledged"}} <-
           Objectives.get_objective(parent_id),
         {:ok, _coordinator} <- Scheduler.start_fanout(parent_id) do
      {:ok, %{message: "Fan-out started.", status: :completed, actions: []}}
    else
      false -> {:error, :confirmation_required}
      {:ok, _objective} -> {:error, :fanout_not_startable}
      {:error, reason} -> {:error, reason}
    end
  end

  defp approved?(context) do
    get_in(context, [:confirmation, :approved?]) == true or
      get_in(context, ["confirmation", "approved?"]) == true
  end
end
