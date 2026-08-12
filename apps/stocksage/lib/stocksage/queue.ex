defmodule StockSage.Queue do
  @moduledoc """
  Durable StockSage queue context.

  v0.20 only records requested work; bridge/native execution lands later.
  """

  import Ecto.Query

  alias AllbertAssist.Repo
  alias StockSage.Domain
  alias StockSage.Domain.{AnalysisQueue, QueueRun}

  @default_limit 50
  @max_limit 100

  def create_entry(attrs) when is_map(attrs) do
    prepared =
      attrs
      |> prepare_attrs("queue")
      |> Domain.put_defaults(%{status: "queued", priority: "normal"})

    AnalysisQueue.changeset(%AnalysisQueue{}, prepared)
    |> Repo.insert()
  end

  def get_entry(user_id, id) do
    normalized_user_id = Domain.normalize_user_id(user_id)

    AnalysisQueue
    |> where([entry], entry.user_id == ^normalized_user_id and entry.id == ^id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  def list_entries(user_id, opts \\ []) do
    normalized_user_id = Domain.normalize_user_id(user_id)
    limit = Domain.normalize_limit(Keyword.get(opts, :limit), @default_limit, @max_limit)
    status = Keyword.get(opts, :status)

    AnalysisQueue
    |> where([entry], entry.user_id == ^normalized_user_id)
    |> maybe_filter_status(status)
    |> order_by([entry], desc: entry.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def update_entry_status(%AnalysisQueue{} = entry, status, attrs \\ %{}) do
    prepared = Map.put(attrs, :status, status)

    AnalysisQueue.changeset(entry, prepared)
    |> Repo.update()
  end

  def create_run(%AnalysisQueue{} = entry, attrs \\ %{}) do
    prepared =
      attrs
      |> atomize_known_keys()
      |> Map.put_new(:queue_id, entry.id)
      |> Map.put_new(:user_id, entry.user_id)
      |> Domain.put_generated_id("queue_run")
      |> Domain.put_defaults(%{status: "started", started_at: DateTime.utc_now()})

    QueueRun.changeset(%QueueRun{}, prepared)
    |> Repo.insert()
  end

  def get_run(user_id, id) do
    normalized_user_id = Domain.normalize_user_id(user_id)

    QueueRun
    |> where([run], run.user_id == ^normalized_user_id and run.id == ^id)
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      run -> {:ok, run}
    end
  end

  def list_runs(user_id, queue_id, opts \\ []) do
    normalized_user_id = Domain.normalize_user_id(user_id)
    limit = Domain.normalize_limit(Keyword.get(opts, :limit), 25, 100)

    QueueRun
    |> where([run], run.user_id == ^normalized_user_id and run.queue_id == ^queue_id)
    |> order_by([run], desc: run.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  defp prepare_attrs(attrs, prefix) do
    attrs
    |> atomize_known_keys()
    |> Domain.put_generated_id(prefix)
  end

  defp atomize_known_keys(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, String.to_existing_atom(key), value)
    end)
  rescue
    ArgumentError -> attrs
  end

  defp maybe_filter_status(query, nil), do: query
  defp maybe_filter_status(query, ""), do: query

  defp maybe_filter_status(query, status) do
    where(query, [entry], entry.status == ^status)
  end
end
