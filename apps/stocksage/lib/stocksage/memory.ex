defmodule StockSage.Memory do
  @moduledoc """
  StockSage-local memory context.

  These records are SQLite domain data. They are not markdown Allbert memory
  and are never auto-promoted by v0.20.
  """

  import Ecto.Query

  alias AllbertAssist.Repo
  alias StockSage.Domain
  alias StockSage.Domain.MemoryEntry

  @default_limit 50
  @max_limit 100

  def create_entry(attrs) when is_map(attrs) do
    prepared =
      attrs
      |> prepare_attrs("memory")
      |> Domain.put_defaults(%{kind: "note", source: "operator", tags: %{}})

    MemoryEntry.changeset(%MemoryEntry{}, prepared)
    |> Repo.insert()
  end

  def upsert_entry(attrs) when is_map(attrs) do
    with {:ok, user_id} <- required_string(attrs, :user_id),
         {:ok, legacy_source} <- required_string(attrs, :legacy_source),
         {:ok, legacy_id} <- required_string(attrs, :legacy_id) do
      case get_entry_by_legacy(user_id, legacy_source, legacy_id) do
        nil -> create_entry(attrs)
        entry -> update_entry(entry, attrs)
      end
    else
      _ -> create_entry(attrs)
    end
  end

  def update_entry(%MemoryEntry{} = entry, attrs) when is_map(attrs) do
    sanitized =
      attrs
      |> Map.delete(:id)
      |> Map.delete("id")

    MemoryEntry.changeset(entry, sanitized)
    |> Repo.update()
  end

  def get_entry(user_id, id) do
    normalized_user_id = Domain.normalize_user_id(user_id)

    MemoryEntry
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
    kind = Keyword.get(opts, :kind)
    analysis_id = Keyword.get(opts, :analysis_id)

    MemoryEntry
    |> where([entry], entry.user_id == ^normalized_user_id)
    |> maybe_filter_kind(kind)
    |> maybe_filter_analysis(analysis_id)
    |> order_by([entry], desc: entry.updated_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def get_entry_by_legacy(user_id, legacy_source, legacy_id) do
    MemoryEntry
    |> where(
      [entry],
      entry.user_id == ^Domain.normalize_user_id(user_id) and
        entry.legacy_source == ^legacy_source and entry.legacy_id == ^legacy_id
    )
    |> Repo.one()
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

  defp required_string(attrs, key) do
    value = AllbertAssist.Maps.field_truthy(attrs, key)

    if is_binary(value) and String.trim(value) != "" do
      {:ok, String.trim(value)}
    else
      :error
    end
  end

  defp maybe_filter_kind(query, nil), do: query
  defp maybe_filter_kind(query, ""), do: query

  defp maybe_filter_kind(query, kind) do
    where(query, [entry], entry.kind == ^kind)
  end

  defp maybe_filter_analysis(query, nil), do: query
  defp maybe_filter_analysis(query, ""), do: query

  defp maybe_filter_analysis(query, analysis_id) do
    where(query, [entry], entry.analysis_id == ^analysis_id)
  end
end
