defmodule AllbertAssist.Memory.ReviewCadence do
  @moduledoc """
  Applies `memory.review_cadence` to the single Jobs.Managed projection rebuild.

  This module owns no timer or parallel job identity. A settings write asks
  `Jobs.Managed` to reconcile the reserved entry, then changes only its ordinary
  schedule and pause state.
  """

  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Managed

  @identity "memory-index-rebuild"
  @run_at "03:00"

  @spec sync(term(), map()) :: {:ok, map()} | {:error, term()}
  def sync(cadence, context \\ %{})

  def sync(cadence, context) when cadence in ["manual", "daily", "weekly"] do
    user_id = user_id(context)

    with {:ok, reconciliation} <- Managed.reconcile_identity(@identity, user_id),
         :ok <- reconciliation_ready(reconciliation),
         %Job{} = job <- managed_job(user_id),
         {:ok, updated} <- apply_cadence(job, cadence) do
      {:ok,
       %{
         source: :memory_review_cadence,
         action: diagnostic_action(reconciliation.outcome, cadence),
         cadence: cadence,
         job_id: updated.id
       }}
    else
      nil -> {:error, :memory_index_rebuild_job_missing}
      {:error, reason} -> {:error, reason}
    end
  end

  def sync(cadence, _context), do: {:error, {:unsupported_memory_review_cadence, cadence}}

  defp apply_cadence(%Job{} = job, "manual") do
    with {:ok, scheduled} <- Jobs.update_job(job, cadence_attrs(job, "manual")) do
      if scheduled.status == "paused", do: {:ok, scheduled}, else: Jobs.pause_job(scheduled)
    end
  end

  defp apply_cadence(%Job{} = job, cadence) do
    with {:ok, scheduled} <- Jobs.update_job(job, cadence_attrs(job, cadence)) do
      if scheduled.status == "active", do: {:ok, scheduled}, else: Jobs.resume_job(scheduled)
    end
  end

  defp cadence_attrs(job, cadence) do
    %{
      schedule: schedule(cadence),
      metadata: Map.put(job.metadata || %{}, "cadence", cadence)
    }
  end

  defp reconciliation_ready(%{outcome: :managed_name_conflict, reason: reason}),
    do: {:error, {:managed_memory_job_conflict, reason}}

  defp reconciliation_ready(_result), do: :ok

  defp diagnostic_action(_outcome, "manual"), do: :paused
  defp diagnostic_action(:created, _cadence), do: :created
  defp diagnostic_action(_outcome, _cadence), do: :updated

  defp managed_job(user_id) do
    user_id
    |> Jobs.list_jobs(limit: 100)
    |> Enum.find(fn job -> job.name == @identity and Managed.managed?(job) end)
  end

  defp schedule("manual"), do: %{kind: "manual"}
  defp schedule("daily"), do: %{kind: "daily", at: @run_at}
  defp schedule("weekly"), do: %{kind: "weekly", weekday: "sunday", at: @run_at}

  defp user_id(context) when is_map(context) do
    request = Map.get(context, :request, context)

    [
      Map.get(request, :user_id),
      Map.get(request, "user_id"),
      Map.get(request, :operator_id),
      Map.get(request, "operator_id"),
      Map.get(request, :actor),
      Map.get(request, "actor"),
      "local"
    ]
    |> Enum.find(&present?/1)
    |> to_string()
  end

  defp user_id(_context), do: "local"

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value), do: not is_nil(value)
end
