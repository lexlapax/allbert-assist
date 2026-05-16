defmodule AllbertAssist.Memory.Index do
  @moduledoc """
  Rebuildable JSON index for markdown memory entries.
  """

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Entry

  @header "# DERIVED - DO NOT EDIT"
  @index_file ".index.json"
  @stop_words ~w[a an and are about do for from in is me my of on the to what you]

  @doc "Return the memory index path for a root."
  @spec path(String.t()) :: String.t()
  def path(root), do: Path.join(root, @index_file)

  @doc "Build an in-memory index map from markdown entries."
  @spec build(binary(), keyword()) ::
          {:ok,
           %{
             String.t() => true | String.t() | non_neg_integer() | [map()]
           }}
  def build(root, opts \\ []) when is_binary(root) do
    max_entries = Keyword.get(opts, :max_entries, 1000)

    with {:ok, entries} <- Memory.list_entries(limit: max_entries) do
      {:ok,
       %{
         "derived" => true,
         "derived_at" => now(),
         "source" => Path.join(root, "*/*.md"),
         "entry_count" => length(entries),
         "entries" => Enum.map(entries, &index_entry/1)
       }}
    end
  end

  @doc "Load the on-disk index, stripping the derived-artifact comment header."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(root) when is_binary(root) do
    root
    |> path()
    |> File.read()
    |> case do
      {:ok, content} ->
        content
        |> strip_header()
        |> Jason.decode()

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Query an index map and load matching entries from markdown."
  @spec query(map(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def query(index, query, opts \\ []) when is_map(index) and is_binary(query) do
    limit = Keyword.get(opts, :limit, 10)
    user_id = Keyword.get(opts, :user_id)
    categories = Keyword.get(opts, :categories)
    tokens = tokens(query)

    index
    |> Map.get("entries", [])
    |> Enum.filter(&entry_searchable?(&1, user_id, categories))
    |> Enum.map(&score_index_entry(&1, tokens))
    |> Enum.filter(fn {score, _entry} -> score > 0 end)
    |> Enum.sort_by(
      fn {score, entry} -> {score, Map.get(entry, "timestamp"), Map.get(entry, "path")} end,
      :desc
    )
    |> Enum.take(limit)
    |> Enum.reduce_while({:ok, []}, fn {score, index_entry}, {:ok, acc} ->
      case Memory.read_entry(index_entry["path"], user_id: user_id) do
        {:ok, %Entry{} = entry} ->
          result =
            entry
            |> Entry.to_map(include_body: false)
            |> Map.put(:score, Float.round(score, 3))
            |> Map.put(:match_reasons, match_reasons(index_entry, tokens))

          {:cont, {:ok, [result | acc]}}

        {:error, _reason} ->
          {:cont, {:ok, acc}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      other -> other
    end
  end

  @doc "Return true when the index is absent or older than any active markdown entry."
  @spec stale?(String.t()) :: boolean()
  def stale?(root) when is_binary(root) do
    index_path = path(root)

    with {:ok, %{mtime: index_mtime}} <- File.stat(index_path, time: :posix) do
      root
      |> active_markdown_files()
      |> Enum.any?(&newer_than?(&1, index_mtime))
    else
      {:error, _reason} -> true
    end
  end

  defp newer_than?(file, index_mtime) do
    case File.stat(file, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime > index_mtime
      {:error, _reason} -> false
    end
  end

  @doc "Encode an index map with the derived-artifact header."
  @spec encode(map()) :: {:ok, String.t()} | {:error, term()}
  def encode(index) when is_map(index) do
    case Jason.encode(index, pretty: true) do
      {:ok, json} -> {:ok, "#{@header}\n# Rebuilt: #{index["derived_at"]}\n#{json}\n"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Tokenize search text for index matching."
  @spec tokens(String.t()) :: [String.t()]
  def tokens(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.uniq()
  end

  def tokens(_text), do: []

  defp index_entry(%Entry{} = entry) do
    haystack = Enum.join([entry.summary, entry.body, Atom.to_string(entry.category)], " ")

    %{
      "path" => entry.path,
      "category" => Atom.to_string(entry.category),
      "summary" => entry.summary,
      "timestamp" => entry.timestamp,
      "actor" => entry.actor,
      "review_status" => Atom.to_string(entry.review_status),
      "tokens" => tokens(haystack)
    }
  end

  defp strip_header(content) do
    content
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, "#"))
    |> Enum.join("\n")
  end

  defp entry_searchable?(entry, user_id, categories) do
    status = Map.get(entry, "review_status")

    status not in ["flagged", "prune_nominated"] and
      user_matches?(entry, user_id) and
      category_matches?(entry, categories)
  end

  defp user_matches?(_entry, nil), do: true
  defp user_matches?(entry, user_id), do: Map.get(entry, "actor") == user_id

  defp category_matches?(_entry, nil), do: true

  defp category_matches?(entry, categories) when is_list(categories) do
    Map.get(entry, "category") in Enum.map(categories, &to_string/1)
  end

  defp category_matches?(entry, category), do: Map.get(entry, "category") == to_string(category)

  defp score_index_entry(entry, []), do: {0.0, entry}

  defp score_index_entry(entry, query_tokens) do
    entry_tokens = Map.get(entry, "tokens", [])
    token_matches = Enum.count(query_tokens, &(&1 in entry_tokens))

    recency =
      entry
      |> Map.get("timestamp")
      |> recency_score()

    score = min(1.0, token_matches * 0.35 + recency)
    {score, entry}
  end

  defp match_reasons(entry, query_tokens) do
    matches = Enum.filter(query_tokens, &(&1 in Map.get(entry, "tokens", [])))

    Enum.map(matches, &"keyword:#{&1}")
  end

  defp recency_score(timestamp) do
    with {:ok, datetime, _offset} <- DateTime.from_iso8601(timestamp) do
      age_days = max(0, DateTime.diff(DateTime.utc_now(), datetime, :day))
      max(0.0, 0.15 - age_days / 365 * 0.15)
    else
      _error -> 0.0
    end
  end

  defp active_markdown_files(root) do
    root
    |> Path.join("*/*.md")
    |> Path.wildcard()
    |> Enum.reject(&(Path.basename(&1) |> String.starts_with?(".")))
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
