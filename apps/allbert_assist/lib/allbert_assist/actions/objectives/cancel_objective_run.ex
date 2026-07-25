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
  alias AllbertAssist.Objectives.Runs.Scheduler
  alias AllbertAssist.Security.PermissionGate

  @tiers %{cooperative: 1, supervised: 2, os_kill: 3}
  @cancellable_statuses ~w[open running blocked]

  @impl true
  def run(params, context) do
    decision = PermissionGate.authorize(:objective_write, context)
    objective_id = field(params, :objective_id)
    user_id = field(context, :user_id) || field(params, :user_id)
    reason = field(params, :reason)

    with true <- PermissionGate.allowed?(decision),
         {:ok, objective} <- Objectives.get_objective(objective_id),
         true <- objective.user_id == user_id,
         true <- is_binary(reason) and String.trim(reason) != "" do
      respond(objective, decision, cancel_targets(objective, user_id, reason))
    else
      false -> {:ok, denied(decision)}
      {:error, {:objective_not_found, _objective_id}} -> {:ok, error(decision, :not_found)}
    end
  end

  defp cancel_targets(%{fanout_role: "parent"} = parent, user_id, reason) do
    case Fanout.parent_projection(parent) do
      %{phase: phase, children: children} when phase in [:awaiting_kickoff, :running] ->
        active_children = Enum.filter(children, &(&1.status in @cancellable_statuses))

        with :ok <- request_all(active_children, user_id, reason),
             {:ok, tier} <- cancel_all(active_children, user_id, reason),
             {:ok, join} <- Fanout.reconcile_parent(parent.id, recovered?: false),
             {:ok, joined} <- require_joined(join) do
          {:ok, {:cancelled, tier, joined}}
        end

      %{phase: :recovering} ->
        _ = Scheduler.wake_parent(parent.id)
        {:ok, {:finalizing, parent}}

      %{phase: :joined, parent: joined} ->
        {:ok, {:already_finished, joined}}

      %{phase: :inconsistent} ->
        {:error, :fanout_state_inconsistent}
    end
  end

  defp cancel_targets(objective, user_id, reason) do
    with :ok <- request_all([objective], user_id, reason),
         {:ok, tier} <- cancel_all([objective], user_id, reason),
         {:ok, cancelled} <- Objectives.get_objective(objective.id) do
      {:ok, {:cancelled, tier, cancelled}}
    end
  end

  defp respond(requested, decision, {:ok, {:cancelled, tier, final}}) do
    {:ok,
     %{
       message: cancellation_message(requested, final, tier),
       status: :cancelled,
       cancellation_tier: tier,
       final_status: final.status,
       join_outcome: final.join_outcome,
       permission_decision: decision,
       actions: [
         %{
           name: "cancel_objective_run",
           status: :cancelled,
           objective_id: requested.id,
           cancellation_tier: tier
         }
       ]
     }}
  end

  defp respond(requested, decision, {:ok, {:finalizing, final}}) do
    {:ok,
     %{
       message:
         "Fan-out #{requested.id} has no active tasks; Allbert is finalizing its durable report.",
       status: :finalizing,
       final_status: final.status,
       permission_decision: decision,
       actions: [%{name: "cancel_objective_run", status: :finalizing, objective_id: requested.id}]
     }}
  end

  defp respond(requested, decision, {:ok, {:already_finished, final}}) do
    {:ok,
     %{
       message:
         "Fan-out #{requested.id} already finished as #{final.status}/#{final.join_outcome}.",
       status: :already_finished,
       final_status: final.status,
       join_outcome: final.join_outcome,
       permission_decision: decision,
       actions: [
         %{name: "cancel_objective_run", status: :already_finished, objective_id: requested.id}
       ]
     }}
  end

  defp respond(_requested, decision, {:error, reason}), do: {:ok, error(decision, reason)}

  defp request_all(targets, user_id, reason) do
    Enum.reduce_while(targets, :ok, &request_one(&1, &2, user_id, reason))
  end

  defp cancel_all(targets, user_id, reason) do
    Enum.reduce_while(targets, {:ok, :cooperative}, &cancel_one(&1, &2, user_id, reason))
  end

  defp request_one(objective, :ok, user_id, reason) do
    case Objectives.request_cancellation(user_id, objective.id, reason) do
      {:ok, _requested} -> {:cont, :ok}
      {:error, error} -> continue_if_terminal(objective.id, :ok, error)
    end
  end

  defp cancel_one(objective, {:ok, highest}, user_id, reason) do
    {:ok, tier} = Cancel.cancel(objective.id)
    persist_cancel(objective, user_id, reason, highest, tier)
  end

  defp persist_cancel(objective, user_id, reason, highest, tier) do
    case Objectives.cancel(user_id, objective.id, reason) do
      {:ok, _result} -> record_cancel_tier(objective.id, reason, highest, tier)
      {:error, error} -> continue_terminal_cancel(objective.id, highest, tier, error)
    end
  end

  defp record_cancel_tier(objective_id, reason, highest, tier) do
    case record_tier(objective_id, tier, reason) do
      {:ok, _event} -> {:cont, {:ok, higher_tier(highest, tier)}}
      {:error, error} -> {:halt, {:error, error}}
    end
  end

  defp continue_terminal_cancel(objective_id, highest, tier, error) do
    continue_if_terminal(objective_id, {:ok, higher_tier(highest, tier)}, error)
  end

  defp continue_if_terminal(objective_id, continuation, error) do
    if terminal_now?(objective_id),
      do: {:cont, continuation},
      else: {:halt, {:error, error}}
  end

  defp terminal_now?(objective_id) do
    case Objectives.get_objective(objective_id) do
      {:ok, %{status: status}} -> status not in @cancellable_statuses
      _other -> false
    end
  end

  defp require_joined({kind, parent}) when kind in [:joined_now, :already_joined],
    do: {:ok, parent}

  defp require_joined(:not_terminal), do: {:error, :fanout_cancellation_incomplete}

  defp cancellation_message(%{fanout_role: "parent"} = requested, final, tier) do
    "Stopped remaining work for #{requested.id} (#{tier}); " <>
      "final outcome is #{final.status}/#{final.join_outcome}."
  end

  defp cancellation_message(requested, _final, tier),
    do: "Objective run #{requested.id} cancelled (#{tier})."

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
