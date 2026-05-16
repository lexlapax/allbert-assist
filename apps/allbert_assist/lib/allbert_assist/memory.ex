defmodule AllbertAssist.Memory do
  @moduledoc """
  Markdown-first memory store for the v0.01 local assistant loop.

  Markdown files are the source of truth. Runtime/indexed views can grow later,
  but M5 keeps writes and reads simple, inspectable, and portable.
  """

  @categories [:notes, :preferences, :traces, :skills]
  @recall_categories [:notes, :preferences, :skills]
  @default_limit 5

  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Memory.Review

  @type category :: :notes | :preferences | :traces | :skills

  @type entry :: %{
          optional(:content) => String.t(),
          path: String.t(),
          category: category(),
          timestamp: String.t(),
          source_signal_id: String.t(),
          actor: String.t(),
          agent: String.t(),
          channel: String.t(),
          summary: String.t(),
          body: String.t(),
          review_status: Entry.review_status(),
          reviewed_at: String.t() | nil,
          reviewed_by: String.t() | nil,
          correction_note: String.t() | nil
        }

  @doc "Return supported markdown memory categories."
  def categories, do: @categories

  @doc """
  Return the memory root.

  Precedence:

  1. `config :allbert_assist, AllbertAssist.Memory, root: "..."`
  2. `ALLBERT_MEMORY_ROOT`
  3. `<ALLBERT_HOME>/memory`, with `ALLBERT_HOME_DIR` as an accepted alias and
     `~/.allbert` as the default home
  """
  @spec root() :: String.t()
  def root do
    AllbertAssist.Paths.memory_root()
  end

  @doc "Create the memory root and all initial category directories."
  @spec ensure_root!() :: String.t()
  def ensure_root! do
    root = root()

    Enum.each(@categories, fn category ->
      root
      |> Path.join(Atom.to_string(category))
      |> File.mkdir_p!()
    end)

    root
  end

  @doc "Append one markdown memory entry."
  @spec append(map()) :: {:ok, entry()} | {:error, term()}
  def append(attrs) when is_map(attrs) do
    with {:ok, category} <- normalize_category(Map.get(attrs, :category, :notes)),
         {:ok, body} <- normalize_body(Map.get(attrs, :body)),
         {:ok, entry} <- build_entry(attrs, category, body),
         :ok <- write_entry(entry) do
      {:ok, entry}
    end
  end

  def append(_attrs), do: {:error, :invalid_memory_attrs}

  @doc "Read recent markdown memory entries, optionally ranked by query terms."
  @spec recent(keyword()) :: {:ok, [entry()]}
  def recent(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, @default_limit)
    query = Keyword.get(opts, :query, "")
    categories = Keyword.get(opts, :categories, @recall_categories)

    entries =
      ensure_root!()
      |> memory_files(categories)
      |> Enum.flat_map(&read_entry_file/1)
      |> rank_entries(query)
      |> Enum.take(limit)

    {:ok, entries}
  end

  @doc "List parsed markdown memory entries with optional filters."
  @spec list_entries(keyword()) :: {:ok, [Entry.t()]}
  def list_entries(opts \\ []) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 50)
    category = Keyword.get(opts, :category)
    review_status = Keyword.get(opts, :review_status)
    since = Keyword.get(opts, :since)
    user_id = Keyword.get(opts, :user_id)
    categories = categories_for_filter(category)

    entries =
      ensure_root!()
      |> memory_files(categories)
      |> Enum.flat_map(&read_entry_file/1)
      |> Enum.map(&Entry.from_map/1)
      |> filter_by_user(user_id)
      |> filter_by_review_status(review_status)
      |> filter_since(since)
      |> Enum.sort_by(&{&1.timestamp, &1.path}, :desc)
      |> Enum.take(limit)

    {:ok, entries}
  end

  @doc "Read one active memory entry by path."
  @spec read_entry(String.t(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def read_entry(path, opts \\ [])

  def read_entry(path, opts) when is_binary(path) and is_list(opts) do
    user_id = Keyword.get(opts, :user_id)

    with {:ok, path} <- normalize_active_path(path),
         {:ok, content} <- File.read(path),
         entry <- Entry.from_map(parse_entry(path, content)),
         :ok <- authorize_entry_user(entry, user_id) do
      {:ok, entry}
    else
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def read_entry(_path, _opts), do: {:error, :invalid_path}

  defp normalize_category(category) when category in @categories, do: {:ok, category}

  defp normalize_category(category) when is_binary(category) do
    category
    |> String.to_existing_atom()
    |> normalize_category()
  rescue
    ArgumentError -> {:error, {:invalid_category, category}}
  end

  defp normalize_category(category), do: {:error, {:invalid_category, category}}

  defp normalize_body(body) when is_binary(body) do
    case String.trim(body) do
      "" -> {:error, :empty_memory}
      body -> {:ok, body}
    end
  end

  defp normalize_body(_body), do: {:error, :missing_memory}

  defp build_entry(attrs, category, body) do
    timestamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    summary = summarize(Map.get(attrs, :summary) || body)
    actor = Map.get(attrs, :actor, "local") |> to_string()
    agent = Map.get(attrs, :agent, "AllbertAssist.Agents.IntentAgent") |> to_string()
    source_signal_id = Map.get(attrs, :source_signal_id, "unknown") |> to_string()
    channel = Map.get(attrs, :channel, "unknown") |> to_string()
    path = entry_path(category, timestamp, summary)

    {:ok,
     %{
       path: path,
       category: category,
       timestamp: timestamp,
       source_signal_id: source_signal_id,
       actor: actor,
       agent: agent,
       channel: channel,
       summary: summary,
       body: body,
       review_status: :unreviewed,
       reviewed_at: nil,
       reviewed_by: nil,
       correction_note: nil
     }}
  end

  defp write_entry(entry) do
    entry.path
    |> Path.dirname()
    |> File.mkdir_p!()

    File.write(entry.path, render_entry(entry))
  end

  defp render_entry(entry) do
    """
    # Memory: #{entry.summary}

    - Timestamp: #{entry.timestamp}
    - Category: #{entry.category}
    - Source signal: #{entry.source_signal_id}
    - Actor: #{entry.actor}
    - Agent: #{entry.agent}
    - Channel: #{entry.channel}

    ## Body

    #{entry.body}
    """
    |> String.trim()
    |> Kernel.<>("\n")
  end

  defp entry_path(category, timestamp, summary) do
    filename =
      "#{timestamp_slug(timestamp)}-#{slug(summary)}-#{System.unique_integer([:positive])}.md"

    root()
    |> Path.join(Atom.to_string(category))
    |> Path.join(filename)
  end

  defp memory_files(root, categories) do
    categories
    |> Enum.filter(&(&1 in @categories))
    |> Enum.flat_map(fn category ->
      root
      |> Path.join(Atom.to_string(category))
      |> Path.join("*.md")
      |> Path.wildcard()
    end)
    |> Enum.sort(:desc)
  end

  defp read_entry_file(path) do
    case File.read(path) do
      {:ok, content} -> [parse_entry(path, content)]
      {:error, _reason} -> []
    end
  end

  @doc false
  def parse_entry(path, content) do
    review = Review.parse_review(content)

    %{
      path: path,
      category: category_from_path(path),
      timestamp: metadata(content, "Timestamp"),
      source_signal_id: metadata(content, "Source signal"),
      actor: metadata(content, "Actor"),
      agent: metadata(content, "Agent"),
      channel: metadata(content, "Channel"),
      summary: summary_from_content(content),
      body: body_from_content(content),
      content: content,
      review_status: review.review_status,
      reviewed_at: review.reviewed_at,
      reviewed_by: review.reviewed_by,
      correction_note: review.correction_note,
      review: review
    }
  end

  defp category_from_path(path) do
    path
    |> Path.dirname()
    |> Path.basename()
    |> String.to_existing_atom()
  rescue
    ArgumentError -> :notes
  end

  defp metadata(content, key) do
    case Regex.run(~r/^- #{Regex.escape(key)}: (.+)$/m, content) do
      [_, value] -> String.trim(value)
      _match -> ""
    end
  end

  defp summary_from_content(content) do
    case Regex.run(~r/^# Memory: (.+)$/m, content) do
      [_, summary] -> String.trim(summary)
      _match -> ""
    end
  end

  defp body_from_content(content) do
    case String.split(content, "## Body", parts: 2) do
      [_prefix, body] ->
        body
        |> String.split("\n## Review", parts: 2)
        |> hd()
        |> String.trim()

      _other ->
        ""
    end
  end

  defp categories_for_filter(nil), do: @categories

  defp categories_for_filter(category) do
    case normalize_category(category) do
      {:ok, category} -> [category]
      {:error, _reason} -> []
    end
  end

  defp filter_by_user(entries, nil), do: entries

  defp filter_by_user(entries, user_id) do
    Enum.filter(entries, &(&1.actor == to_string(user_id)))
  end

  defp filter_by_review_status(entries, nil), do: entries

  defp filter_by_review_status(entries, review_status) do
    review_status = normalize_review_status(review_status)
    Enum.filter(entries, &(&1.review_status == review_status))
  end

  defp filter_since(entries, nil), do: entries

  defp filter_since(entries, since) when is_binary(since) do
    Enum.filter(entries, &(&1.timestamp >= since))
  end

  defp filter_since(entries, _since), do: entries

  defp normalize_review_status(status) when is_atom(status), do: status

  defp normalize_review_status(status) when is_binary(status) do
    case status do
      "kept" -> :kept
      "flagged" -> :flagged
      "prune_nominated" -> :prune_nominated
      _other -> :unreviewed
    end
  end

  defp normalize_review_status(_status), do: :unreviewed

  defp normalize_active_path(path) do
    root = ensure_root!() |> Path.expand()
    expanded = Path.expand(path)
    deleted_root = Path.join(root, "deleted")

    cond do
      not String.starts_with?(expanded, root <> "/") ->
        {:error, :path_outside_memory_root}

      String.starts_with?(expanded, deleted_root <> "/") ->
        {:error, :not_found}

      Path.extname(expanded) != ".md" ->
        {:error, :invalid_path}

      true ->
        {:ok, expanded}
    end
  end

  defp authorize_entry_user(_entry, nil), do: :ok
  defp authorize_entry_user(%Entry{actor: actor}, user_id) when actor == user_id, do: :ok
  defp authorize_entry_user(_entry, _user_id), do: {:error, :not_found}

  defp rank_entries(entries, query) do
    tokens = query_tokens(query)

    entries
    |> Enum.map(&{score_entry(&1, tokens), &1})
    |> Enum.sort_by(fn {score, entry} -> {score, entry.timestamp, entry.path} end, :desc)
    |> Enum.map(fn {_score, entry} -> entry end)
  end

  defp score_entry(_entry, []), do: 0

  defp score_entry(entry, tokens) do
    haystack =
      [entry.summary, entry.body, Atom.to_string(entry.category)]
      |> Enum.join(" ")
      |> String.downcase()

    Enum.count(tokens, &String.contains?(haystack, &1))
  end

  defp query_tokens(query) when is_binary(query) do
    query
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in ["what", "do", "you", "remember", "about", "my", "the", "a", "an"]))
  end

  defp query_tokens(_query), do: []

  defp summarize(text) do
    text
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, 96)
  end

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
    |> case do
      "" -> "memory"
      slug -> slug
    end
  end

  defp timestamp_slug(timestamp) do
    String.replace(timestamp, ~r/[^0-9A-Za-z]+/, "-")
  end
end
