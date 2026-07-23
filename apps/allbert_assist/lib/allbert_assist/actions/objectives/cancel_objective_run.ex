defmodule AllbertAssist.Actions.Objectives.CancelObjectiveRun do
  @moduledoc "Cancel an owned fan-out run through cooperative, supervised, and OS tiers."

  use AllbertAssist.Action,
    permission: :objective_write,
    exposure: :agent,
    execution_mode: :objective_engine,
    skill_backed?: false,
    confirmation: :not_required,
    name: "cancel_objective_run",
    description: "Cancel an owned fan-out or child run and its scoped OS execution.",
    category: "objectives",
    tags: ["objectives", "cancel", "safety"],
    schema: [
      objective_id: [type: :string, required: true],
      reason: [type: :string, required: true]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Maps
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.Objectives.Runs.Cancel
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Signals

  @tiers %{cooperative: 1, supervised: 2, os_kill: 3}

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:objective_write, context)
    objective_id = field(params, :objective_id)
    user_id = field(context, :user_id) || field(params, :user_id)
    reason = field(params, :reason)

    with true <- PermissionGate.allowed?(decision),
         {:ok, objective} <- Objectives.get_objective(objective_id),
         true <- objective.user_id == user_id,
         true <- is_binary(reason) and String.trim(reason) != "",
         {:ok, tier} <- cancel_targets(objective, user_id, reason) do
      {:ok,
       %{
         message: "Objective run #{objective.id} cancelled (#{tier}).",
         status: :cancelled,
         cancellation_tier: tier,
         permission_decision: decision,
         actions: [
           %{
             name: "cancel_objective_run",
             status: :cancelled,
             objective_id: objective.id,
             cancellation_tier: tier
           }
         ]
       }}
    else
      false -> {:ok, denied(decision)}
      {:error, :not_found} -> {:ok, error(decision, :not_found)}
      {:error, reason} -> {:ok, error(decision, reason)}
    end
  end

  defp cancel_targets(%{fanout_role: "parent"} = parent, user_id, reason) do
    targets = Fanout.children(parent) ++ [parent]
    cancel_all(targets, user_id, reason)
  end

  defp cancel_targets(objective, user_id, reason), do: cancel_all([objective], user_id, reason)

  defp cancel_all(targets, user_id, reason) do
    Enum.reduce_while(targets, {:ok, :cooperative}, fn objective, {:ok, highest} ->
      with {:ok, tier} <- Cancel.cancel(objective.id),
           {:ok, _result} <- Objectives.cancel(user_id, objective.id, reason),
           {:ok, _event} <- record_tier(objective.id, tier, reason) do
        Signals.emit_fanout(:run_cancelled, %{
          child_id: objective.id,
          parent_id: objective.parent_objective_id,
          cancellation_tier: tier
        })

        {:cont, {:ok, higher_tier(highest, tier)}}
      else
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp record_tier(objective_id, tier, reason) do
    Objectives.create_event(%{
      objective_id: objective_id,
      kind: "run_cancelled",
      summary: "Run cancellation reached #{tier}",
      payload: %{tier: tier, reason: reason}
    })
  end

  defp higher_tier(left, right), do: if(@tiers[left] >= @tiers[right], do: left, else: right)

  defp denied(decision),
    do: %{message: decision.reason, status: :denied, permission_decision: decision, actions: []}

  defp error(decision, reason),
    do: %{
      message: "Unable to cancel objective run: #{inspect(reason)}",
      status: :error,
      error: reason,
      permission_decision: decision,
      actions: []
    }

  defp field(map, key), do: Maps.field(map, key)
end
