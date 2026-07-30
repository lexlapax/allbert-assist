defmodule AllbertAssist.Memory.Retrieval do
  @moduledoc """
  Shared compatibility retrieval over the Memory projection and bounded Markdown.

  The projection is the only compiled candidate authority. The Markdown path is
  intentionally bounded and exists only for explicit `search_memory` fallback;
  prompt insertion and Intent never call it.
  """

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Memory.Projection

  @stop_words ~w[a an and are about do for from in is me my of on the to what you]
  @default_candidate_limit 500
  @maximum_candidate_limit 10_000

  @doc "Search the verified projection and canonically revalidate returned candidates."
  @spec projection_search(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def projection_search(query, opts \\ [])

  def projection_search(query, opts) when is_binary(query) and is_list(opts) do
    terms = terms(query)
    projection = Keyword.get(opts, :projection, Projection)
    now = temporal_opt(opts, :now, DateTime.utc_now())
    valid_at = temporal_opt(opts, :valid_at, now)
    known_at = temporal_opt(opts, :known_at, now)

    with {:ok, projection_result} <-
           Projection.candidates(
             terms,
             [
               user_id: Keyword.get(opts, :user_id),
               categories: Keyword.get(opts, :categories),
               valid_at: valid_at,
               known_at: known_at,
               limit: candidate_limit(opts)
             ],
             projection
           ) do
      {valid, invalid} =
        revalidate(projection_result.candidates, valid_at, known_at, projection)

      {:ok,
       projection_result
       |> Map.drop([:candidates])
       |> Map.merge(%{
         entries: rank(valid, terms, output_limit(opts), now),
         canonical_revalidation_failure_count: length(invalid)
       })}
    end
  catch
    :exit, _reason -> {:error, :memory_projection_not_ready}
  end

  def projection_search(_query, _opts), do: {:error, :invalid_memory_query}

  @doc "Search a bounded set of canonical Markdown claims without a compiled artifact."
  @spec markdown_search(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def markdown_search(query, opts \\ [])

  def markdown_search(query, opts) when is_binary(query) and is_list(opts) do
    terms = terms(query)
    now = temporal_opt(opts, :now, DateTime.utc_now())
    valid_at = temporal_opt(opts, :valid_at, now)
    known_at = temporal_opt(opts, :known_at, now)
    user_id = normalize_optional(Keyword.get(opts, :user_id))
    categories = normalize_categories(Keyword.get(opts, :categories))
    candidate_limit = candidate_limit(opts)

    paths = Claims.claim_paths()

    candidates =
      paths
      |> Enum.take(candidate_limit)
      |> Enum.flat_map(&canonical_candidate(&1, valid_at, known_at))
      |> Enum.filter(&eligible?(&1.entry, user_id, categories))

    {:ok,
     %{
       entries: rank(candidates, terms, output_limit(opts), now),
       scanned_count: min(length(paths), candidate_limit),
       bounded?: true,
       candidate_limit: candidate_limit
     }}
  end

  def markdown_search(_query, _opts), do: {:error, :invalid_memory_query}

  @doc "Normalize deterministic lexical terms shared by compatibility callers."
  @spec terms(String.t()) :: [String.t()]
  def terms(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(&1 in @stop_words))
    |> Enum.uniq()
  end

  def terms(_text), do: []

  defp revalidate(candidates, valid_at, known_at, projection) do
    candidates
    |> Enum.reduce({[], []}, fn candidate, {valid, invalid} ->
      binding = Map.take(candidate, [:claim_id, :sequence, :revision_digest])

      case Claims.revalidate_projection_candidate(binding, valid_at, known_at) do
        :ok -> {[candidate | valid], invalid}
        {:error, reason} -> {valid, [reason | invalid]}
      end
    end)
    |> then(fn {valid, invalid} ->
      if invalid != [], do: Projection.queue_repair(invalid, projection)
      {Enum.reverse(valid), Enum.reverse(invalid)}
    end)
  end

  defp canonical_candidate(path, valid_at, known_at) do
    with {:ok, stream} <- Claims.read_path(path),
         {:ok, candidate} <- candidate_at(stream, valid_at, known_at),
         :ok <-
           Claims.revalidate_projection_candidate(
             Map.take(candidate, [:claim_id, :sequence, :revision_digest]),
             valid_at,
             known_at
           ) do
      [candidate]
    else
      _error -> []
    end
  end

  defp candidate_at(%{status: :valid} = stream, valid_at, known_at) do
    with {:ok, record} <- Claims.as_of(stream.claim_id, valid_at, known_at) do
      {:ok,
       %{
         claim_id: stream.claim_id,
         sequence: record["sequence"],
         revision_digest: record["revision_digest"],
         entry: entry_from_record(stream.path, record)
       }}
    end
  end

  defp candidate_at(%{status: :grandfathered} = stream, _valid_at, _known_at) do
    with {:ok, %Entry{review_status: :kept} = entry} <- Memory.read_entry(stream.path) do
      {:ok,
       %{
         claim_id: stream.claim_id,
         sequence: 0,
         revision_digest: stream.legacy_digest,
         entry: entry
       }}
    end
  end

  defp candidate_at(_stream, _valid_at, _known_at), do: {:error, :claim_not_retrievable}

  defp entry_from_record(path, record) do
    payload = record["payload"] || %{}
    category = payload["category"] || path_category(path)
    operator_id = payload["operator_id"] || actor_id(record["actor"])

    Entry.from_map(%{
      path: path,
      category: category,
      timestamp: record["recorded_at"],
      actor: operator_id,
      origin: payload["origin"],
      app_id: payload["app_id"],
      namespace: projected_namespace(payload["namespace"], category),
      kind: record["action"],
      source_ref: source_ref(payload),
      summary: claim_summary(payload),
      body: claim_value(payload),
      review_status: :kept,
      reviewed_at: record["recorded_at"],
      reviewed_by: operator_id
    })
  end

  defp rank(candidates, query_terms, limit, now) do
    candidates
    |> Enum.map(&score_candidate(&1, query_terms, now))
    |> Enum.filter(fn {score, _candidate} -> score > 0 end)
    |> Enum.sort_by(
      fn {score, candidate} -> {score, candidate.entry.timestamp, candidate.entry.path} end,
      :desc
    )
    |> Enum.take(limit)
    |> Enum.map(fn {score, candidate} ->
      candidate.entry
      |> Entry.to_map(include_body: false)
      |> Map.put(:score, Float.round(score, 3))
      |> Map.put(:match_reasons, match_reasons(candidate.entry, query_terms))
    end)
  end

  defp score_candidate(candidate, [], _now), do: {0.0, candidate}

  defp score_candidate(candidate, query_terms, now) do
    entry_terms = entry_terms(candidate.entry)
    matches = Enum.count(query_terms, &(&1 in entry_terms))
    score = min(0.5, matches * 0.35 + recency_score(candidate.entry.timestamp, now))
    {score, candidate}
  end

  defp match_reasons(entry, query_terms) do
    terms = entry_terms(entry)

    query_terms
    |> Enum.filter(&(&1 in terms))
    |> Enum.map(&"keyword:#{&1}")
  end

  defp entry_terms(entry) do
    terms(Enum.join([entry.summary, entry.body, Atom.to_string(entry.category)], " "))
  end

  defp recency_score(timestamp, now) do
    case parse_datetime(timestamp) do
      %DateTime{} = datetime ->
        age_days = max(0, DateTime.diff(now, datetime, :day))
        max(0.0, 0.15 - age_days / 365 * 0.15)

      nil ->
        0.0
    end
  end

  defp eligible?(entry, user_id, categories) do
    (is_nil(user_id) or entry.actor == user_id) and
      (is_nil(categories) or Atom.to_string(entry.category) in categories)
  end

  defp normalize_categories(nil), do: nil

  defp normalize_categories(categories) do
    categories
    |> List.wrap()
    |> Enum.map(&normalize_optional/1)
    |> Enum.reject(&is_nil/1)
  end

  defp candidate_limit(opts) do
    opts
    |> Keyword.get(:candidate_limit, @default_candidate_limit)
    |> clamp(1, @maximum_candidate_limit, @default_candidate_limit)
  end

  defp output_limit(opts), do: opts |> Keyword.get(:limit, 10) |> clamp(1, 50, 10)

  defp clamp(value, minimum, maximum, _default) when is_integer(value),
    do: value |> max(minimum) |> min(maximum)

  defp clamp(_value, _minimum, _maximum, default), do: default

  defp temporal_opt(opts, key, default) do
    opts
    |> Keyword.get(key, default)
    |> parse_datetime()
    |> case do
      nil -> default
      datetime -> datetime
    end
  end

  defp parse_datetime(%DateTime{} = datetime), do: datetime

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp claim_value(payload) do
    value = payload["value"] || payload["object"] || payload["body"] || payload["claim"]
    if is_binary(value), do: value, else: Jason.encode!(value || payload)
  end

  defp claim_summary(payload) do
    [payload["subject"], payload["predicate"]]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(" ")
    |> case do
      "" -> claim_value(payload) |> first_line()
      summary -> summary
    end
  end

  defp first_line(value) do
    value
    |> String.split("\n", parts: 2)
    |> List.first()
    |> String.slice(0, 200)
  end

  defp source_ref(payload) do
    case payload["source_evidence"] do
      [%{} = source | _rest] -> source["source_id"] || source["message_id"]
      _other -> payload["source_ref"]
    end
  end

  defp actor_id("operator:" <> actor), do: actor
  defp actor_id(actor) when is_binary(actor), do: actor
  defp actor_id(_actor), do: nil

  defp path_category(path), do: path |> Path.dirname() |> Path.basename()

  defp projected_namespace(namespace, "identity") when namespace in [nil, "", "default"],
    do: "identity"

  defp projected_namespace(namespace, _category), do: namespace

  defp normalize_optional(nil), do: nil

  defp normalize_optional(value) do
    case value |> to_string() |> String.trim() do
      "" -> nil
      normalized -> normalized
    end
  end
end
