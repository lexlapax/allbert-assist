defmodule AllbertAssist.Memory.ReviewCadence do
  @moduledoc """
  Synchronizes `memory.review_cadence` with a managed scheduled job.

  The job is ordinary durable scheduler data. This module only creates or
  updates the template-backed job when the setting is written.
  """

  alias AllbertAssist.Jobs
  alias AllbertAssist.Jobs.Job
  alias AllbertAssist.Jobs.Templates

  @template_name "memory-index-rebuild"
  @managed_by "memory.review_cadence"
  @run_at "03:00"

  @spec sync(term(), map()) :: {:ok, map()} | {:error, term()}
  def sync(cadence, context \\ %{})

  def sync(cadence, context) when cadence in ["daily", "weekly"] do
    user_id = user_id(context)

    case cadence_job(user_id) do
      %Job{} = job -> update_cadence_job(job, cadence)
      nil -> create_cadence_job(user_id, cadence)
    end
  end

  def sync("manual", context) do
    user_id = user_id(context)

    case managed_cadence_job(user_id) do
      %Job{} = job ->
        with {:ok, paused} <- Jobs.pause_job(job) do
          {:ok,
           %{
             source: :memory_review_cadence,
             action: :paused,
             cadence: "manual",
             job_id: paused.id
           }}
        end

      nil ->
        {:ok, %{source: :memory_review_cadence, action: :none, cadence: "manual"}}
    end
  end

  def sync(cadence, _context), do: {:error, {:unsupported_memory_review_cadence, cadence}}

  defp create_cadence_job(user_id, cadence) do
    with {:ok, attrs} <- Templates.expand(@template_name, %{}),
         {:ok, job} <-
           attrs
           |> Map.merge(%{
             user_id: user_id,
             operator_id: user_id,
             schedule: schedule(cadence),
             status: "active",
             metadata: metadata(cadence)
           })
           |> Jobs.create_job() do
      {:ok,
       %{
         source: :memory_review_cadence,
         action: :created,
         cadence: cadence,
         job_id: job.id
       }}
    end
  end

  defp update_cadence_job(%Job{} = job, cadence) do
    with {:ok, updated} <-
           Jobs.update_job(job, %{
             schedule: schedule(cadence),
             status: "active",
             metadata: Map.merge(job.metadata || %{}, metadata(cadence))
           }) do
      {:ok,
       %{
         source: :memory_review_cadence,
         action: :updated,
         cadence: cadence,
         job_id: updated.id
       }}
    end
  end

  defp cadence_job(user_id) do
    user_id
    |> Jobs.list_jobs(limit: 100)
    |> Enum.find(&template_job?/1)
  end

  defp managed_cadence_job(user_id) do
    user_id
    |> Jobs.list_jobs(limit: 100)
    |> Enum.find(&managed_template_job?/1)
  end

  defp template_job?(%Job{} = job),
    do: metadata_value(job.metadata, "template_name") == @template_name

  defp managed_template_job?(%Job{} = job) do
    template_job?(job) and metadata_value(job.metadata, "managed_by") == @managed_by
  end

  defp schedule("daily"), do: %{kind: "daily", at: @run_at}
  defp schedule("weekly"), do: %{kind: "weekly", weekday: "sunday", at: @run_at}

  defp metadata(cadence) do
    %{
      "template_name" => @template_name,
      "managed_by" => @managed_by,
      "cadence" => cadence
    }
  end

  defp metadata_value(metadata, key) when is_map(metadata) do
    Map.get(metadata, key) || Map.get(metadata, metadata_atom_key(key))
  end

  defp metadata_value(_metadata, _key), do: nil

  defp metadata_atom_key("template_name"), do: :template_name
  defp metadata_atom_key("managed_by"), do: :managed_by
  defp metadata_atom_key("cadence"), do: :cadence
  defp metadata_atom_key(_key), do: nil

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
