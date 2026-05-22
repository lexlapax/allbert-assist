defmodule AllbertAssist.Memory do
  @moduledoc """
  Markdown-first memory store for the v0.01 local assistant loop.

  Markdown files are the source of truth. Runtime/indexed views can grow later,
  but M5 keeps writes and reads simple, inspectable, and portable.
  """

  @categories [:notes, :preferences, :traces, :skills]
  @recall_categories [:notes, :preferences, :skills]
  @default_limit 5

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Memory.Review
  alias AllbertAssist.Paths

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
          app_id: String.t() | nil,
          namespace: String.t() | nil,
          kind: String.t() | nil,
          idempotency_key: String.t() | nil,
          source_ref: String.t() | nil,
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

  @doc """
  Append or update a namespaced app memory entry.

  Namespaced writes validate the app namespace declared through the app
  registry and are idempotent by `{actor, app_id, namespace, idempotency_key}`.
  """
  @spec upsert_app_entry(map()) :: {:ok, Entry.t()} | {:error, term()}
  def upsert_app_entry(attrs) when is_map(attrs) do
    with {:ok, app_id} <- normalize_app_id(Map.get(attrs, :app_id, Map.get(attrs, "app_id"))),
         {:ok, namespace} <-
           normalize_namespace(Map.get(attrs, :namespace, Map.get(attrs, "namespace"))),
         :ok <- validate_writable_namespace(app_id, namespace),
         {:ok, kind} <- required_string(attrs, :kind),
         {:ok, idempotency_key} <- required_string(attrs, :idempotency_key),
         {:ok, source_ref} <- required_string(attrs, :source_ref),
         {:ok, body} <- normalize_body(Map.get(attrs, :body, Map.get(attrs, "body"))) do
      actor = attrs |> value(:actor, "local") |> to_string()
      summary = value(attrs, :summary, body)

      case find_app_entry(actor, app_id, namespace, idempotency_key) do
        {:ok, %Entry{} = entry} ->
          update_entry(entry.path, %{summary: summary, body: body}, user_id: actor)

        {:error, :not_found} ->
          append(%{
            category: value(attrs, :category, :notes),
            summary: summary,
            body: body,
            actor: actor,
            agent: value(attrs, :agent, "AllbertAssist.AppMemory"),
            channel: value(attrs, :channel, "app"),
            source_signal_id: value(attrs, :source_signal_id, "unknown"),
            app_id: app_id,
            namespace: namespace,
            kind: kind,
            idempotency_key: idempotency_key,
            source_ref: source_ref
          })
          |> case do
            {:ok, entry} -> read_entry(entry.path, user_id: actor)
            error -> error
          end
      end
    end
  end

  def upsert_app_entry(_attrs), do: {:error, :invalid_app_memory_attrs}

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
    app_id = Keyword.get(opts, :app_id)
    namespace = Keyword.get(opts, :namespace)
    kind = Keyword.get(opts, :kind)
    idempotency_key = Keyword.get(opts, :idempotency_key)
    categories = categories_for_filter(category)

    entries =
      ensure_root!()
      |> memory_files(categories)
      |> Enum.flat_map(&read_entry_file/1)
      |> Enum.map(&Entry.from_map/1)
      |> filter_by_user(user_id)
      |> filter_by_app_id(app_id)
      |> filter_by_namespace(namespace)
      |> filter_by_kind(kind)
      |> filter_by_idempotency_key(idempotency_key)
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

  @doc "Write or replace the review section on one active memory entry."
  @spec review_entry(String.t(), map(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def review_entry(path, attrs, opts \\ [])

  def review_entry(path, attrs, opts) when is_binary(path) and is_map(attrs) do
    user_id = Keyword.get(opts, :user_id)

    with {:ok, path} <- normalize_active_path(path),
         {:ok, entry} <- read_entry(path, user_id: user_id),
         {:ok, content} <- File.read(path),
         {:ok, updated} <- Review.write_review(content, attrs),
         :ok <- File.write(path, updated) do
      read_entry(entry.path, user_id: user_id)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def review_entry(_path, _attrs, _opts), do: {:error, :invalid_review}

  @doc "Update body and/or summary while preserving metadata and review state."
  @spec update_entry(String.t(), map(), keyword()) :: {:ok, Entry.t()} | {:error, term()}
  def update_entry(path, attrs, opts \\ [])

  def update_entry(path, attrs, opts) when is_binary(path) and is_map(attrs) do
    user_id = Keyword.get(opts, :user_id)

    with {:ok, path} <- normalize_active_path(path),
         {:ok, entry} <- read_entry(path, user_id: user_id),
         {:ok, content} <- File.read(path),
         {:ok, updated} <- update_entry_content(content, attrs),
         {:ok, reviewed} <- maybe_write_correction_review(updated, attrs, entry, user_id),
         :ok <- File.write(path, reviewed) do
      read_entry(entry.path, user_id: user_id)
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def update_entry(_path, _attrs, _opts), do: {:error, :invalid_update}

  @doc "Move active entries into the deleted-memory archive."
  @spec archive_entries([String.t()], keyword()) :: {:ok, [map()]} | {:error, term()}
  def archive_entries(paths, opts \\ []) when is_list(paths) and is_list(opts) do
    user_id = Keyword.get(opts, :user_id)

    paths
    |> Enum.reduce_while({:ok, []}, fn path, {:ok, archived} ->
      case archive_entry(path, user_id: user_id) do
        {:ok, item} -> {:cont, {:ok, [item | archived]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, archived} -> {:ok, Enum.reverse(archived)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Move one active entry into the deleted-memory archive."
  @spec archive_entry(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def archive_entry(path, opts \\ [])

  def archive_entry(path, opts) when is_binary(path) and is_list(opts) do
    user_id = Keyword.get(opts, :user_id)

    with {:ok, entry} <- read_entry(path, user_id: user_id),
         {:ok, source} <- normalize_active_path(entry.path),
         destination <- deleted_path(source, entry.timestamp),
         :ok <- File.mkdir_p(Path.dirname(destination)),
         :ok <- File.rename(source, destination) do
      {:ok,
       %{
         path: source,
         archived_path: destination,
         category: entry.category,
         summary: entry.summary,
         user_id: entry.actor
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  def archive_entry(_path, _opts), do: {:error, :invalid_path}

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
    app_id = optional_metadata(attrs, :app_id)
    namespace = optional_metadata(attrs, :namespace)
    kind = optional_metadata(attrs, :kind)
    idempotency_key = optional_metadata(attrs, :idempotency_key)
    source_ref = optional_metadata(attrs, :source_ref)
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
       app_id: app_id,
       namespace: namespace,
       kind: kind,
       idempotency_key: idempotency_key,
       source_ref: source_ref,
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
    app_metadata =
      [
        {"App ID", entry.app_id},
        {"Namespace", entry.namespace},
        {"Kind", entry.kind},
        {"Idempotency key", entry.idempotency_key},
        {"Source ref", entry.source_ref}
      ]
      |> Enum.reject(fn {_key, value} -> blank?(value) end)
      |> Enum.map_join("\n", fn {key, value} -> "- #{key}: #{value}" end)

    """
    # Memory: #{entry.summary}

    - Timestamp: #{entry.timestamp}
    - Category: #{entry.category}
    - Source signal: #{entry.source_signal_id}
    - Actor: #{entry.actor}
    - Agent: #{entry.agent}
    - Channel: #{entry.channel}
    #{app_metadata}

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
    |> Enum.reject(&(Path.basename(&1) |> String.starts_with?(".")))
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
      app_id: metadata(content, "App ID"),
      namespace: metadata(content, "Namespace"),
      kind: metadata(content, "Kind"),
      idempotency_key: metadata(content, "Idempotency key"),
      source_ref: metadata(content, "Source ref"),
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

  defp update_entry_content(content, attrs) do
    body = Map.get(attrs, :body, Map.get(attrs, "body"))
    summary = Map.get(attrs, :summary, Map.get(attrs, "summary"))

    if blank?(body) and blank?(summary) do
      {:error, :missing_update}
    else
      content
      |> maybe_replace_summary(summary)
      |> maybe_replace_body(body)
      |> then(&{:ok, &1})
    end
  end

  defp maybe_replace_summary(content, summary) when is_binary(summary) do
    summary = String.trim(summary)

    if summary == "" do
      content
    else
      Regex.replace(~r/^# Memory: .+$/m, content, "# Memory: #{summary}", global: false)
    end
  end

  defp maybe_replace_summary(content, _summary), do: content

  defp maybe_replace_body(content, body) when is_binary(body) do
    body = String.trim(body)

    if body == "" do
      content
    else
      [before_review, review_suffix] =
        case String.split(content, "\n## Review", parts: 2) do
          [prefix, suffix] -> [prefix, "\n## Review" <> suffix]
          [prefix] -> [prefix, ""]
        end

      updated_body =
        case String.split(before_review, "## Body", parts: 2) do
          [prefix, _old_body] -> "#{String.trim(prefix)}\n\n## Body\n\n#{body}"
          [_prefix] -> "#{String.trim(before_review)}\n\n## Body\n\n#{body}"
        end

      "#{updated_body}#{review_suffix}"
      |> String.trim()
      |> Kernel.<>("\n")
    end
  end

  defp maybe_replace_body(content, _body), do: content

  defp maybe_write_correction_review(content, attrs, entry, user_id) do
    note = Map.get(attrs, :note, Map.get(attrs, :correction_note, Map.get(attrs, "note")))

    if blank?(note) do
      {:ok, content}
    else
      status =
        case entry.review_status do
          :unreviewed -> :kept
          status -> status
        end

      Review.write_review(content, %{
        status: status,
        reviewed_by: user_id || entry.actor,
        note: note
      })
    end
  end

  defp filter_by_app_id(entries, nil), do: entries

  defp filter_by_app_id(entries, app_id) do
    case normalize_app_id(app_id) do
      {:ok, app_id} -> Enum.filter(entries, &(&1.app_id == Atom.to_string(app_id)))
      {:error, _reason} -> []
    end
  end

  defp filter_by_namespace(entries, nil), do: entries

  defp filter_by_namespace(entries, namespace) do
    case normalize_namespace(namespace) do
      {:ok, namespace} -> Enum.filter(entries, &(&1.namespace == Atom.to_string(namespace)))
      {:error, _reason} -> []
    end
  end

  defp filter_by_kind(entries, nil), do: entries
  defp filter_by_kind(entries, ""), do: entries

  defp filter_by_kind(entries, kind) do
    kind = metadata_value(kind)
    Enum.filter(entries, &(&1.kind == kind))
  end

  defp filter_by_idempotency_key(entries, nil), do: entries
  defp filter_by_idempotency_key(entries, ""), do: entries

  defp filter_by_idempotency_key(entries, idempotency_key) do
    idempotency_key = metadata_value(idempotency_key)
    Enum.filter(entries, &(&1.idempotency_key == idempotency_key))
  end

  defp find_app_entry(actor, app_id, namespace, idempotency_key) do
    list_entries(
      user_id: actor,
      app_id: app_id,
      namespace: namespace,
      idempotency_key: idempotency_key,
      limit: 1
    )
    |> case do
      {:ok, [%Entry{} = entry | _rest]} -> {:ok, entry}
      {:ok, []} -> {:error, :not_found}
    end
  end

  defp normalize_app_id(app_id) do
    case AppRegistry.normalize_app_id(app_id) do
      {:ok, nil} -> {:error, :missing_app_id}
      {:ok, app_id} -> {:ok, app_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp normalize_namespace(namespace) when is_atom(namespace) and not is_nil(namespace),
    do: {:ok, namespace}

  defp normalize_namespace(namespace) when is_binary(namespace) do
    normalized =
      namespace
      |> String.trim()
      |> String.downcase()

    cond do
      normalized == "" ->
        {:error, :missing_namespace}

      Regex.match?(~r/^[a-z][a-z0-9_]*$/, normalized) ->
        {:ok, String.to_existing_atom(normalized)}

      true ->
        {:error, :unknown_namespace}
    end
  rescue
    ArgumentError -> {:error, :unknown_namespace}
  end

  defp normalize_namespace(_namespace), do: {:error, :missing_namespace}

  defp validate_writable_namespace(app_id, namespace) do
    AppRegistry.registered_memory_namespaces()
    |> Enum.find(fn declaration ->
      declaration.app_id == app_id and declaration.namespace == namespace
    end)
    |> case do
      %{writable: true} -> :ok
      %{writable: false} -> {:error, {:memory_namespace_not_writable, namespace}}
      nil -> {:error, {:unknown_memory_namespace, namespace}}
    end
  end

  defp required_string(attrs, key) do
    case value(attrs, key, nil) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing_required, key}}
          trimmed -> {:ok, trimmed}
        end

      value when is_atom(value) and not is_nil(value) ->
        {:ok, Atom.to_string(value)}

      value when is_integer(value) or is_float(value) ->
        {:ok, to_string(value)}

      _value ->
        {:error, {:missing_required, key}}
    end
  end

  defp optional_metadata(attrs, key) do
    attrs
    |> value(key, nil)
    |> metadata_value()
    |> case do
      "" -> nil
      value -> value
    end
  end

  defp metadata_value(nil), do: ""
  defp metadata_value(value) when is_binary(value), do: String.trim(value)
  defp metadata_value(value) when is_atom(value), do: Atom.to_string(value)
  defp metadata_value(value), do: value |> to_string() |> String.trim()

  defp value(map, key, default) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp value(_map, _key, default), do: default

  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""

  defp deleted_path(source, timestamp) do
    month =
      case DateTime.from_iso8601(timestamp) do
        {:ok, datetime, _offset} -> Calendar.strftime(datetime, "%Y-%m")
        _other -> Date.utc_today() |> Calendar.strftime("%Y-%m")
      end

    Paths.memory_deleted_root()
    |> Path.join(month)
    |> Path.join(Path.basename(source))
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
