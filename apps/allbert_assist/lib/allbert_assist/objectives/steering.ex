defmodule AllbertAssist.Objectives.Steering do
  @moduledoc """
  Durable, ownership-bound steering for active objective runs.

  Directives are events rather than process state. The Registry notification is
  only a wake-up hint; lifecycle boundaries reconcile the durable stream, which
  makes steering safe across executor restarts.
  """

  alias AllbertAssist.{Confirmations, Objectives, Repo, Signals}

  def steer(user_id, objective_id, directive)
      when is_binary(user_id) and is_binary(objective_id) and is_binary(directive) do
    with {:ok, objective} <- Objectives.get_objective(user_id, objective_id),
         :ok <- ensure_active(objective),
         {:ok, event} <- record_directive(objective, String.trim(directive)) do
      notify_runner(objective.id, event.id)
      {:ok, %{objective: objective, directive_event: event}}
    end
  end

  defp ensure_active(%{status: status}) when status in ~w[open running blocked], do: :ok
  defp ensure_active(_objective), do: {:error, :terminal}

  @spec apply_pending(String.t()) :: {:ok, map()} | {:error, term()}
  def apply_pending(objective_id) when is_binary(objective_id) do
    with {:ok, objective} <- Objectives.get_objective(objective_id) do
      events = Objectives.list_events(objective_id, limit: 200)

      applied =
        MapSet.new(
          for e <- events, e.kind == "steer_applied", do: payload(e)["directive_event_id"]
        )

      events
      |> Enum.filter(&(&1.kind == "steer_directive" and not MapSet.member?(applied, &1.id)))
      |> Enum.reverse()
      |> Enum.reduce_while({:ok, objective}, &apply_pending_event/2)
    end
  end

  defp apply_pending_event(event, {:ok, current}) do
    case apply_one(current, event) do
      {:ok, updated} -> {:cont, {:ok, updated}}
      error -> {:halt, error}
    end
  end

  defp record_directive(objective, directive) when directive != "" do
    event_id = Objectives.new_id("evt")

    Repo.transaction(fn ->
      with :ok <- cancel_parked_confirmation(objective, event_id),
           {:ok, event} <-
             Objectives.create_event(%{
               id: event_id,
               objective_id: objective.id,
               kind: "steer_directive",
               summary: "Operator steered objective",
               payload: %{directive: directive}
             }) do
        event
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, reason}
    end
  end

  defp record_directive(_objective, ""), do: {:error, :empty_directive}

  defp cancel_parked_confirmation(objective, steering_event_id) do
    objective.id
    |> Objectives.list_steps()
    |> Enum.filter(&(&1.status == "blocked" and is_binary(&1.confirmation_id)))
    |> Enum.reduce_while(:ok, fn step, :ok ->
      case cancel_confirmation(step.confirmation_id, steering_event_id) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp cancel_confirmation(confirmation_id, steering_event_id) do
    case Confirmations.read(confirmation_id) do
      {:ok, %{"status" => "pending"}} ->
        Confirmations.resolve(confirmation_id, "cancelled", %{
          "reason" => "superseded_by_steer",
          "steering_event_id" => steering_event_id
        })
        |> case do
          {:ok, _record} -> :ok
          {:error, reason} -> {:error, reason}
        end

      {:ok, _record} ->
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp apply_one(objective, event) do
    directive = payload(event)["directive"]

    Repo.transaction(fn ->
      with {:ok, updated} <-
             Objectives.update_objective(objective, %{
               title: String.slice(directive, 0, 200),
               objective: directive,
               progress_summary: "Steered: #{String.slice(directive, 0, 180)}",
               review_reason: nil,
               status: "running"
             }),
           {:ok, _} <-
             Objectives.create_event(%{
               objective_id: objective.id,
               kind: "steer_applied",
               summary: "Steering applied at lifecycle boundary",
               payload: %{directive_event_id: event.id}
             }) do
        updated
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
    |> case do
      {:ok, updated} ->
        Signals.emit_fanout(:run_steered, %{
          child_id: updated.id,
          parent_id: updated.parent_objective_id
        })

        {:ok, updated}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp notify_runner(child_id, event_id) do
    case Registry.lookup(AllbertAssist.Objectives.Runs.Registry, {:run, child_id}) do
      [{pid, _token}] -> send(pid, {:steer_directive, event_id})
      [] -> :ok
    end
  end

  defp payload(event) do
    case Jason.decode(event.payload || "{}") do
      {:ok, value} -> value
      _ -> %{}
    end
  end
end
