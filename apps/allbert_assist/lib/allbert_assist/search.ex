defmodule AllbertAssist.Search do
  @moduledoc """
  Central, surface-neutral conversation Search API.

  The FTS projection proposes bounded lexical candidates. Canonical Corpus
  reauthorization remains authoritative immediately before every result, so a
  stale index row can never grant disclosure.
  """

  alias AllbertAssist.Conversations.Corpus
  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Search.Cursor
  alias AllbertAssist.Search.Page
  alias AllbertAssist.Search.Projection
  alias AllbertAssist.Search.Query
  alias AllbertAssist.Search.QueryScope
  alias AllbertAssist.Search.Result
  alias AllbertAssist.Settings

  @candidate_batch 100
  @max_batches 5
  @max_candidates 500
  @local_surfaces ~w[cli live_view web tui]

  @type error ::
          :invalid_query
          | :invalid_filter
          | :invalid_limit
          | :search_disabled
          | :search_not_ready
          | :search_changed
          | :scope_denied
          | :query_confirmation_required
          | :query_resubmit_required
          | :query_chain_expired

  @doc "Run one bounded conversation search for a verified surface context."
  @spec query(map(), map()) :: {:ok, Page.t()} | {:error, error() | term()}
  def query(request, context \\ %{})

  def query(request, context) when is_map(request) and is_map(context) do
    with :ok <- enabled(),
         {:ok, parsed} <- Query.parse(request),
         {:ok, scope} <- request_scope(parsed, context),
         {:ok, cursor} <- decode_cursor(parsed, scope),
         {:ok, page} <- execute(parsed, scope, cursor, context) do
      {:ok, page}
    end
  end

  def query(_request, _context), do: {:error, :invalid_query}

  @doc "Return the Search-owned, content-free request summary."
  def trace_summary(request) when is_map(request) do
    case Query.parse(request) do
      {:ok, parsed} -> Query.trace_summary(parsed)
      {:error, reason} -> %{validation_error: reason}
    end
  end

  def trace_summary(_request), do: %{validation_error: :invalid_query}

  defp execute(query, scope, cursor, context) do
    projection = Map.get(context, :search_projection, Projection)
    position = if cursor, do: cursor.position

    acc = %{
      results: [],
      scanned: 0,
      filtered: 0,
      batches: 0,
      position: position,
      generation_id: nil,
      projection_revision: nil,
      indexed_through: nil,
      last_indexed_at_us: nil,
      more?: false,
      incomplete?: false
    }

    with {:ok, scanned} <- scan(query, scope, cursor, projection, acc),
         {:ok, next_cursor} <- next_cursor(query, scope, scanned) do
      {:ok,
       %Page{
         results: scanned.results,
         next_cursor: next_cursor,
         generation_id: scanned.generation_id,
         projection_revision: scanned.projection_revision,
         indexed_through: scanned.indexed_through,
         freshness_ms: freshness_ms(scanned.last_indexed_at_us),
         scanned_count: scanned.scanned,
         filtered_count: scanned.filtered,
         incomplete: scanned.incomplete?,
         incomplete_reason: if(scanned.incomplete?, do: :reauthorization_scan_budget, else: nil)
       }}
    end
  end

  defp scan(query, scope, cursor, projection, acc) do
    cond do
      length(acc.results) >= query.limit ->
        {:ok, %{acc | more?: true}}

      acc.batches >= @max_batches or acc.scanned >= @max_candidates ->
        {:ok, %{acc | incomplete?: true, more?: true}}

      true ->
        scan_batch(query, scope, cursor, projection, acc)
    end
  end

  defp scan_batch(query, scope, cursor, projection, acc) do
    with {:ok, batch} <- projection_candidates(projection, query, acc.position),
         :ok <- generation_matches(cursor, batch),
         :ok <- stable_generation(acc, batch),
         {:ok, authorized} <- authorize_batch(batch.candidates, scope) do
      queue_repairs(projection, authorized)
      base = put_generation(acc, batch)
      {next, consumed} = consume_candidates(batch.candidates, authorized, query, base)
      short_batch? = length(batch.candidates) < @candidate_batch
      filled? = length(next.results) >= query.limit
      consumed_all? = consumed == length(batch.candidates)

      cond do
        filled? ->
          {:ok, %{next | more?: not (short_batch? and consumed_all?)}}

        short_batch? ->
          {:ok, %{next | more?: false}}

        true ->
          scan(query, scope, cursor, projection, %{next | batches: next.batches + 1})
      end
    end
  end

  defp consume_candidates(candidates, authorized, query, acc) do
    Enum.reduce_while(candidates, {acc, 0}, fn candidate, {current, consumed} ->
      current = %{
        current
        | scanned: current.scanned + 1,
          position: cursor_position(candidate, query.order)
      }

      consume_candidate(
        Map.fetch!(authorized, candidate.source_id),
        candidate,
        query,
        current,
        consumed
      )
    end)
  end

  defp consume_candidate({:ok, envelope}, candidate, query, current, consumed) do
    result = result(envelope, candidate, current, snippet_max_bytes())
    next = %{current | results: current.results ++ [result]}

    if length(next.results) >= query.limit,
      do: {:halt, {next, consumed + 1}},
      else: {:cont, {next, consumed + 1}}
  end

  defp consume_candidate({:error, _reason}, _candidate, _query, current, consumed) do
    {:cont, {%{current | filtered: current.filtered + 1}, consumed + 1}}
  end

  defp authorize_batch(candidates, scope) do
    candidates
    |> Enum.group_by(&authorization_scope(&1, scope))
    |> Enum.reduce_while({:ok, %{}}, fn {candidate_scope, grouped}, {:ok, acc} ->
      authorize_group(grouped, candidate_scope, scope.operator_id, acc)
    end)
  end

  defp authorize_group(grouped, candidate_scope, operator_id, acc) do
    refs = Enum.map(grouped, &Map.take(&1, [:source_id, :content_digest]))

    case Corpus.rehydrate_and_authorize(operator_id, refs, candidate_scope) do
      {:ok, results} ->
        mapped =
          grouped
          |> Enum.zip(results)
          |> Map.new(fn {candidate, result} -> {candidate.source_id, result} end)

        {:cont, {:ok, Map.merge(acc, mapped)}}

      {:error, reason} ->
        {:halt, {:error, normalize_corpus_error(reason)}}
    end
  end

  defp authorization_scope(candidate, %{class: :local_operator}) do
    %{
      consumer: :search,
      origin_scope: candidate.origin_scope,
      e2ee?: candidate.e2ee?
    }
  end

  defp authorization_scope(candidate, %{class: :mapped_operator_dm} = scope) do
    %{
      consumer: :search,
      origin_scope: candidate.origin_scope,
      e2ee?: candidate.e2ee?,
      thread_id: scope.thread_id,
      origin: scope.origin
    }
  end

  defp authorization_scope(candidate, %{class: :mapped_operator_dm_cross_surface}) do
    %{
      consumer: :search,
      origin_scope: candidate.origin_scope,
      e2ee?: candidate.e2ee?
    }
  end

  defp projection_candidates(module, query, position) when is_atom(module),
    do: normalize_projection_result(module.candidates(query, position))

  defp projection_candidates(server, query, position),
    do: normalize_projection_result(Projection.candidates(query, position, server))

  defp normalize_projection_result({:ok, _batch} = result), do: result
  defp normalize_projection_result({:error, :search_not_ready} = result), do: result
  defp normalize_projection_result({:error, _reason}), do: {:error, :search_not_ready}

  defp queue_repairs(projection, authorized) do
    reasons =
      authorized
      |> Map.values()
      |> Enum.flat_map(fn
        {:error, reason} -> [reason]
        {:ok, _envelope} -> []
      end)
      |> Enum.uniq()

    case reasons do
      [] -> :ok
      reasons when is_atom(projection) -> projection.queue_repair(reasons)
      reasons -> Projection.queue_repair(reasons, projection)
    end
  end

  defp put_generation(acc, batch) do
    %{
      acc
      | generation_id: batch.generation_id,
        projection_revision: batch.projection_revision,
        indexed_through: batch.indexed_through,
        last_indexed_at_us: batch.last_indexed_at_us
    }
  end

  defp generation_matches(nil, _batch), do: :ok

  defp generation_matches(cursor, batch) do
    if cursor.generation_id == batch.generation_id and
         cursor.projection_revision == batch.projection_revision,
       do: :ok,
       else: {:error, :search_changed}
  end

  defp stable_generation(%{generation_id: nil}, _batch), do: :ok

  defp stable_generation(acc, batch) do
    if acc.generation_id == batch.generation_id and
         acc.projection_revision == batch.projection_revision,
       do: :ok,
       else: {:error, :search_changed}
  end

  defp next_cursor(_query, _scope, %{more?: false}), do: {:ok, nil}
  defp next_cursor(_query, _scope, %{position: nil}), do: {:ok, nil}

  defp next_cursor(query, scope, acc) do
    Cursor.encode(
      query,
      cursor_scope(scope),
      acc.generation_id,
      acc.projection_revision,
      acc.position,
      query_chain_id: query.query_chain_id,
      expires_at: Map.get(scope, :expires_at)
    )
  end

  defp decode_cursor(%Query{cursor: nil}, _scope), do: {:ok, nil}

  defp decode_cursor(%Query{} = query, scope) do
    with {:ok, cursor} <- Cursor.decode(query.cursor, query, cursor_scope(scope)),
         :ok <- cursor_chain(cursor, query, scope) do
      {:ok, cursor}
    end
  end

  defp cursor_chain(%{query_chain_id: cursor_chain}, query, scope) do
    cond do
      cursor_chain != query.query_chain_id -> {:error, :invalid_query}
      expired?(scope[:expires_at]) -> {:error, :query_chain_expired}
      true -> :ok
    end
  end

  defp request_scope(query, context) do
    operator_id = value(context, :operator_id) || value(context, :user_id)
    surface = value(context, :channel) || value(context, :surface)
    explicit = value(context, :origin_scope)

    request_scope(query, context, operator_id, surface, explicit)
  end

  defp request_scope(_query, _context, operator_id, _surface, _explicit)
       when not is_binary(operator_id) or operator_id == "",
       do: {:error, :scope_denied}

  defp request_scope(_query, _context, operator_id, surface, explicit)
       when explicit in [:local_operator, "local_operator"] or surface in @local_surfaces,
       do: {:ok, %{class: :local_operator, operator_id: operator_id, surface: surface || "local"}}

  defp request_scope(query, context, operator_id, surface, explicit)
       when explicit in [:mapped_operator_dm, "mapped_operator_dm"],
       do: mapped_scope(query, context, operator_id, surface)

  defp request_scope(_query, _context, _operator_id, _surface, _explicit),
    do: {:error, :scope_denied}

  defp mapped_scope(query, context, operator_id, surface) do
    thread_id = value(context, :thread_id)
    origin = value(context, :origin)

    if is_binary(thread_id) and thread_id != "" and valid_origin?(origin) do
      base = %{
        class: :mapped_operator_dm,
        operator_id: operator_id,
        surface: surface,
        thread_id: thread_id,
        origin: origin,
        source_message_id: value(context, :source_message_id),
        expires_at: value(context, :search_query_expires_at)
      }

      maybe_elevate_scope(query, context, base)
    else
      {:error, :scope_denied}
    end
  end

  defp maybe_elevate_scope(query, context, base) do
    maybe_elevate_scope(value(context, :search_scope), query.query_chain_id, query, context, base)
  end

  defp maybe_elevate_scope(scope, _chain_id, _query, _context, base)
       when scope not in [:cross_surface, "cross_surface"],
       do: {:ok, base}

  defp maybe_elevate_scope(_scope, nil, _query, _context, _base),
    do: {:error, :query_confirmation_required}

  defp maybe_elevate_scope(_scope, chain_id, query, context, base) do
    case QueryScope.verify(chain_id, query, context) do
      {:ok, grant} ->
        {:ok,
         %{
           base
           | class: :mapped_operator_dm_cross_surface,
             expires_at: grant.expires_at
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp valid_origin?(origin) when is_map(origin) do
    Enum.all?(~w[owner_scope channel receiver_account_ref provider_thread_key]a, fn key ->
      value(origin, key) |> is_binary()
    end)
  end

  defp valid_origin?(_origin), do: false

  defp cursor_scope(scope) do
    Map.take(scope, [
      :class,
      :operator_id,
      :surface,
      :thread_id,
      :origin,
      :source_message_id,
      :expires_at
    ])
  end

  defp result(%SourceEnvelope{} = envelope, candidate, acc, max_bytes) do
    %Result{
      source_id: envelope.source_id,
      thread_id: envelope.thread_id,
      author: envelope.author,
      trust: envelope.trust,
      surface: envelope.surface,
      timestamp: DateTime.truncate(envelope.inserted_at, :microsecond),
      snippet: bounded_snippet(Redactor.redact(envelope.content), max_bytes),
      score: candidate.score,
      generation_id: acc.generation_id,
      projection_revision: acc.projection_revision
    }
  end

  defp bounded_snippet(content, max_bytes) when byte_size(content) <= max_bytes, do: content

  defp bounded_snippet(content, max_bytes) do
    marker = "…"
    budget = max(max_bytes - byte_size(marker), 0)

    excerpt =
      content
      |> String.graphemes()
      |> Enum.reduce_while("", fn grapheme, acc ->
        if byte_size(acc) + byte_size(grapheme) <= budget,
          do: {:cont, acc <> grapheme},
          else: {:halt, acc}
      end)

    excerpt <> marker
  end

  defp cursor_position(candidate, :relevance), do: candidate.position
  defp cursor_position(candidate, _order), do: Map.drop(candidate.position, [:score])

  defp freshness_ms(nil), do: nil
  defp freshness_ms(value), do: max(div(System.system_time(:microsecond) - value, 1_000), 0)

  defp snippet_max_bytes do
    case Settings.get("search.snippet.max_bytes") do
      {:ok, value} when is_integer(value) and value >= 64 and value <= 1_024 -> value
      _other -> 320
    end
  end

  defp enabled do
    case Settings.get("search.enabled") do
      {:ok, false} -> {:error, :search_disabled}
      _other -> :ok
    end
  end

  defp normalize_corpus_error(:consumer_disabled), do: :search_disabled
  defp normalize_corpus_error(:origin_grant_required), do: :scope_denied
  defp normalize_corpus_error(:e2ee_grant_required), do: :scope_denied
  defp normalize_corpus_error(reason), do: reason

  defp expired?(nil), do: false

  defp expired?(expires_at) when is_integer(expires_at),
    do: System.system_time(:second) >= expires_at

  defp expired?(_expires_at), do: true

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
