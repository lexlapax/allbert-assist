defmodule AllbertAssist.Memory.ActiveMemory do
  @moduledoc """
  Deterministic Active Memory retrieval for direct-answer model context.

  This module is a plain read-only retrieval service. It does not promote,
  mutate, infer, or authorize memory. The runtime-facing boundary is the
  registered `retrieve_active_memory` action.
  """

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Entry
  alias AllbertAssist.Settings

  @seconds_per_day 86_400
  @stop_words_fallback ~w[a an and are about do for from in is me my of on the to what you]

  @type settings :: %{
          enabled?: boolean(),
          top_k: pos_integer(),
          chunk_max_bytes: pos_integer(),
          recency_half_life_days: pos_integer(),
          thread_affinity: %{
            same_thread: float(),
            same_app: float(),
            general: float()
          },
          identity_inclusion: float(),
          internal_candidate_limit: pos_integer(),
          excluded_sample_limit: pos_integer()
        }

  @type result :: %{
          status: atom(),
          enabled?: boolean(),
          query_terms_normalized: [String.t()],
          scope: map(),
          candidate_count_before_filter: non_neg_integer(),
          candidate_chunk_count_before_filter: non_neg_integer(),
          candidate_count_after_filter: non_neg_integer(),
          chunks: [map()],
          retrieved_chunks: [map()],
          excluded_chunks_sample: [map()]
        }

  @doc "Retrieve deterministic top-K Active Memory chunks for a query."
  @spec retrieve(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def retrieve(query, opts \\ [])

  def retrieve(query, opts) when is_binary(query) and is_list(opts) do
    settings = settings()
    scope = scope(opts)
    terms = normalize_terms(query)
    now = now(opts)

    if settings.enabled? do
      retrieve_enabled(settings, scope, terms, now, opts)
    else
      {:ok, empty_result(:disabled, false, terms, scope)}
    end
  end

  def retrieve(_query, _opts), do: {:error, :invalid_active_memory_query}

  @doc "Return the body-free metadata shape used by traces and action metadata."
  @spec trace_metadata(result()) :: map()
  def trace_metadata(result) when is_map(result) do
    result
    |> Map.take([
      :status,
      :enabled?,
      :query_terms_normalized,
      :scope,
      :candidate_count_before_filter,
      :candidate_chunk_count_before_filter,
      :candidate_count_after_filter,
      :retrieved_chunks,
      :excluded_chunks_sample
    ])
  end

  @doc "Normalize query or chunk text with the shipped Active Memory stop words."
  @spec normalize_terms(String.t()) :: [String.t()]
  def normalize_terms(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^a-z0-9]+/, trim: true)
    |> Enum.reject(&(byte_size(&1) < 2))
    |> Enum.reject(&(&1 in stop_words()))
    |> Enum.uniq()
  end

  def normalize_terms(_text), do: []

  defp retrieve_enabled(settings, scope, terms, now, opts) do
    with {:ok, entries} <- list_candidates(opts, settings) do
      chunks = Enum.flat_map(entries, &chunks_for_entry(&1, settings.chunk_max_bytes))
      scored = score_chunks(chunks, terms, scope, now, settings)
      selected = Enum.take(scored, settings.top_k)
      excluded = scored |> Enum.drop(settings.top_k) |> Enum.take(settings.excluded_sample_limit)

      {:ok,
       %{
         status: :completed,
         enabled?: true,
         query_terms_normalized: terms,
         scope: scope,
         candidate_count_before_filter: length(entries),
         candidate_chunk_count_before_filter: length(chunks),
         candidate_count_after_filter: length(scored),
         chunks: Enum.map(selected, &Map.drop(&1, [:score_raw])),
         retrieved_chunks: Enum.map(selected, &chunk_metadata/1),
         excluded_chunks_sample: Enum.map(excluded, &chunk_metadata(&1, :below_top_k))
       }}
    end
  end

  defp list_candidates(opts, settings) do
    opts
    |> Keyword.get(:user_id)
    |> case do
      nil ->
        Memory.list_entries(review_status: :kept, limit: settings.internal_candidate_limit)

      user_id ->
        Memory.list_entries(
          user_id: user_id,
          review_status: :kept,
          limit: settings.internal_candidate_limit
        )
    end
  end

  defp score_chunks(chunks, terms, scope, now, settings) do
    chunks
    |> Enum.flat_map(fn chunk ->
      case score_chunk(chunk, terms, scope, now, settings) do
        {:ok, scored} -> [scored]
        {:excluded, _reason} -> []
      end
    end)
    |> Enum.sort_by(&{-&1.score_raw, &1.chunk_id})
  end

  defp score_chunk(chunk, terms, scope, now, settings) do
    cond do
      terms == [] ->
        {:excluded, :empty_query_terms}

      not eligible_scope?(chunk.entry, scope) ->
        {:excluded, :out_of_scope}

      true ->
        score_scoped_chunk(chunk, terms, scope, now, settings)
    end
  end

  defp score_scoped_chunk(chunk, terms, scope, now, settings) do
    with {:ok, updated_at} <- updated_at(chunk.entry),
         {:ok, recency_decay} <- recency_decay(updated_at, now, settings),
         lexical_match when lexical_match > 0.0 <- lexical_match(terms, chunk.body) do
      thread_affinity = thread_affinity(chunk.entry, scope, settings)
      identity_inclusion = identity_inclusion(chunk.entry, scope, settings)
      score = recency_decay * thread_affinity * identity_inclusion * lexical_match

      {:ok,
       chunk
       |> Map.drop([:entry])
       |> Map.merge(%{
         score_raw: score,
         score: rounded(score),
         recency_decay: rounded(recency_decay),
         thread_affinity: rounded(thread_affinity),
         identity_inclusion: rounded(identity_inclusion),
         lexical_match: rounded(lexical_match)
       })}
    else
      {:error, reason} -> {:excluded, reason}
      value when is_number(value) -> {:excluded, :no_lexical_match}
    end
  end

  defp chunks_for_entry(%Entry{} = entry, chunk_max_bytes) do
    entry.body
    |> to_string()
    |> chunk_text(chunk_max_bytes)
    |> Enum.with_index()
    |> Enum.map(fn {body, index} ->
      %{
        entry: entry,
        chunk_id: chunk_id(entry, index),
        entry_path: entry.path,
        category: entry.category,
        summary: entry.summary,
        body: body,
        byte_size: byte_size(body),
        chunk_index: index,
        origin: entry.origin,
        app_id: entry.app_id,
        namespace: entry.namespace,
        kind: entry.kind,
        source_ref: entry.source_ref,
        updated_at: entry.reviewed_at || entry.timestamp
      }
    end)
  end

  defp chunk_text("", _chunk_max_bytes), do: []

  defp chunk_text(text, chunk_max_bytes) do
    text
    |> String.graphemes()
    |> Enum.reduce({[], "", 0}, fn grapheme, {chunks, current, size} ->
      grapheme_size = byte_size(grapheme)

      if size > 0 and size + grapheme_size > chunk_max_bytes do
        {[current | chunks], grapheme, grapheme_size}
      else
        {chunks, current <> grapheme, size + grapheme_size}
      end
    end)
    |> then(fn
      {chunks, "", 0} -> chunks
      {chunks, current, _size} -> [current | chunks]
    end)
    |> Enum.reverse()
  end

  defp chunk_id(entry, index) do
    digest =
      :crypto.hash(:sha256, "#{entry.path}:#{index}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    "active_memory:#{digest}"
  end

  defp eligible_scope?(entry, scope) do
    if entry.category == :identity do
      identity_chunk?(entry, scope.identity_namespace)
    else
      general_chunk?(entry) or same_app_chunk?(entry, scope.active_app)
    end
  end

  defp identity_chunk?(entry, identity_namespace) do
    entry.category == :identity and
      blank_or?(entry.origin, "system") and
      blank_or?(entry.namespace, identity_namespace) and
      blank?(entry.app_id)
  end

  defp general_chunk?(entry) do
    (blank?(entry.app_id) and blank?(entry.namespace) and entry.category != :identity) or
      (entry.app_id == "allbert" and entry.namespace in [nil, "", "general"])
  end

  defp same_app_chunk?(_entry, nil), do: false

  defp same_app_chunk?(entry, active_app) do
    entry.app_id == active_app
  end

  defp updated_at(entry) do
    [entry.reviewed_at, entry.timestamp]
    |> Enum.find_value(&parse_datetime/1)
    |> case do
      nil -> {:error, :invalid_updated_at}
      datetime -> {:ok, datetime}
    end
  end

  defp parse_datetime(nil), do: nil
  defp parse_datetime(""), do: nil

  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _error -> nil
    end
  end

  defp parse_datetime(_value), do: nil

  defp recency_decay(updated_at, now, settings) do
    age_days =
      now
      |> DateTime.diff(updated_at, :second)
      |> max(0)
      |> Kernel./(@seconds_per_day)

    if age_days > settings.recency_half_life_days * 10 do
      {:error, :stale_by_recency_floor}
    else
      {:ok, :math.pow(2.0, -(age_days / settings.recency_half_life_days))}
    end
  end

  defp lexical_match(terms, body) do
    chunk_terms = MapSet.new(normalize_terms(body))
    matches = Enum.count(terms, &MapSet.member?(chunk_terms, &1))
    matches / max(1, length(terms))
  end

  defp thread_affinity(entry, scope, settings) do
    cond do
      same_thread?(entry, scope.thread_id) ->
        settings.thread_affinity.same_thread

      same_app_chunk?(entry, scope.active_app) ->
        settings.thread_affinity.same_app

      true ->
        settings.thread_affinity.general
    end
  end

  defp same_thread?(_entry, nil), do: false

  defp same_thread?(entry, thread_id) do
    entry.source_ref
    |> to_string()
    |> String.contains?(to_string(thread_id))
  end

  defp identity_inclusion(entry, scope, settings) do
    if identity_chunk?(entry, scope.identity_namespace) do
      settings.identity_inclusion
    else
      1.0
    end
  end

  defp chunk_metadata(chunk, reason \\ nil) do
    chunk
    |> Map.drop([:body, :score_raw])
    |> maybe_put(:excluded_reason, reason)
  end

  defp settings do
    %{
      enabled?: setting("active_memory.enabled", true),
      top_k: setting("active_memory.top_k", 5),
      chunk_max_bytes: setting("active_memory.chunk_max_bytes", 2048),
      recency_half_life_days: setting("active_memory.score_weights.recency_half_life_days", 30),
      thread_affinity: %{
        same_thread: setting("active_memory.score_weights.thread_affinity.same_thread", 1.0),
        same_app: setting("active_memory.score_weights.thread_affinity.same_app", 0.6),
        general: setting("active_memory.score_weights.thread_affinity.general", 0.3)
      },
      identity_inclusion: setting("active_memory.score_weights.identity_inclusion", 1.5),
      internal_candidate_limit: setting("active_memory.internal_candidate_limit", 1_000),
      excluded_sample_limit: setting("active_memory.excluded_sample_limit", 5)
    }
  end

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  end

  defp scope(opts) do
    %{
      thread_id: normalize_blank(Keyword.get(opts, :thread_id)),
      active_app: normalize_active_app(Keyword.get(opts, :active_app)),
      identity_namespace: normalize_identity_namespace(Keyword.get(opts, :identity_namespace))
    }
  end

  defp normalize_active_app(nil), do: nil
  defp normalize_active_app(:allbert), do: nil
  defp normalize_active_app("allbert"), do: nil
  defp normalize_active_app(app) when is_atom(app), do: Atom.to_string(app)

  defp normalize_active_app(app) when is_binary(app) do
    app
    |> String.trim()
    |> case do
      "" -> nil
      "allbert" -> nil
      value -> value
    end
  end

  defp normalize_active_app(_app), do: nil

  defp normalize_identity_namespace(namespace) when is_atom(namespace) and not is_nil(namespace),
    do: Atom.to_string(namespace)

  defp normalize_identity_namespace(namespace) when is_binary(namespace) do
    namespace
    |> String.trim()
    |> case do
      "" -> "identity"
      value -> value
    end
  end

  defp normalize_identity_namespace(_namespace), do: "identity"

  defp now(opts) do
    opts
    |> Keyword.get(:now)
    |> parse_datetime()
    |> case do
      nil -> DateTime.utc_now() |> DateTime.truncate(:second)
      datetime -> datetime
    end
  end

  defp empty_result(status, enabled?, terms, scope) do
    %{
      status: status,
      enabled?: enabled?,
      query_terms_normalized: terms,
      scope: scope,
      candidate_count_before_filter: 0,
      candidate_chunk_count_before_filter: 0,
      candidate_count_after_filter: 0,
      chunks: [],
      retrieved_chunks: [],
      excluded_chunks_sample: []
    }
  end

  @spec stop_words() :: [String.t()]
  defp stop_words do
    case File.read(stop_words_path()) do
      {:ok, words} ->
        words
        |> String.split(~r/\s+/, trim: true)

      {:error, _reason} ->
        @stop_words_fallback
    end
  end

  defp stop_words_path do
    case :code.priv_dir(:allbert_assist) do
      priv when is_list(priv) ->
        priv
        |> to_string()
        |> Path.join("active_memory/stop_words.txt")

      {:error, _reason} ->
        Path.join(File.cwd!(), "apps/allbert_assist/priv/active_memory/stop_words.txt")
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_value), do: false

  defp blank_or?(value, expected), do: blank?(value) or value == expected

  defp normalize_blank(nil), do: nil

  defp normalize_blank(value) when is_binary(value),
    do: if(String.trim(value) == "", do: nil, else: value)

  defp normalize_blank(value), do: value

  defp rounded(value), do: Float.round(value, 6)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
