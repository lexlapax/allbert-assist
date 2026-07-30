defmodule AllbertAssist.DevGates.V13LatencyBench do
  @moduledoc """
  Structured v1.3 Memory/Search latency evidence runner.

  This is development tooling, not a runtime capability. It owns the frozen
  LD 82 scale corpora and records one provenance-carrying TestMetrics row per
  consumer. The release aggregate never invokes it.
  """

  alias AllbertAssist.Conversations
  alias AllbertAssist.Conversations.Message
  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Memory.Projection, as: MemoryProjection
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Search
  alias AllbertAssist.Search.Projection, as: SearchProjection
  alias AllbertAssist.Settings

  @memory_claims 10_000
  @memory_queries 200
  @search_messages 25_000
  @search_threads 250
  @search_queries 300

  def record_run! do
    consumer = System.get_env("V13_LATENCY_CONSUMER", "both")
    store = blank_to_nil(System.get_env("V13_LATENCY_STORE"))
    artifact_sha256 = blank_to_nil(System.get_env("V13_ARTIFACT_SHA256"))
    full_sha = parse_full_sha!(System.get_env("V13_FULL_SHA"))
    dirty = parse_dirty!(System.get_env("V13_DIRTY"))

    consumers = if consumer == "both", do: [:memory, :search], else: [parse_consumer!(consumer)]

    Enum.each(consumers, fn selected ->
      stats = run(selected)
      status = if within_bound?(selected, stats), do: "passed", else: "failed"

      TestMetrics.record(%{
        store: store,
        git_sha: String.slice(full_sha, 0, 8),
        full_sha: full_sha,
        dirty: dirty,
        cwd: "apps/allbert_assist",
        gate: "bench-v13-latency",
        phase_or_step: Atom.to_string(selected),
        corpus_id: corpus_id(selected),
        command: "bench-v13-latency --consumer #{selected}",
        status: status,
        wall_ms: stats.wall_ms,
        stats: Map.put(stats, :artifact_sha256, artifact_sha256)
      })

      IO.puts(format_stats(selected, stats, status))

      if status != "passed" do
        raise "v1.3 #{selected} latency bound missed"
      end
    end)

    :ok
  end

  def run(:memory), do: memory_run()
  def run(:search), do: search_run()

  def summarize(latencies_ms) when is_list(latencies_ms) and latencies_ms != [] do
    %{
      samples: length(latencies_ms),
      p95_ms: percentile(latencies_ms, 0.95),
      p99_ms: percentile(latencies_ms, 0.99)
    }
  end

  def within_bound?(:memory, stats), do: stats.p95_ms <= 75.0 and stats.p99_ms <= 250.0
  def within_bound?(:search, stats), do: stats.p95_ms <= 200.0 and stats.p99_ms <= 750.0

  defp memory_run do
    started = System.monotonic_time(:millisecond)
    write_memory_corpus()

    {:ok, projection} =
      MemoryProjection.start_link(root: Paths.memory_projection_root(), name: nil)

    try do
      {:ok, build} = MemoryProjection.rebuild(projection)

      if build.claim_count != @memory_claims do
        raise "memory benchmark corpus mismatch: #{build.claim_count}"
      end

      queries = memory_queries()
      Enum.each(queries, &memory_query!(&1, projection))

      latencies =
        Enum.map(queries, fn query ->
          Settings.with_resolved_settings(fn ->
            timed(fn -> memory_query_pinned!(query, projection) end)
          end)
        end)

      summarize(latencies)
      |> Map.merge(%{
        consumer: "memory",
        claims: @memory_claims,
        queries: @memory_queries,
        warmup_queries: @memory_queries,
        top_k: 5,
        p95_limit_ms: 75.0,
        p99_limit_ms: 250.0,
        wall_ms: System.monotonic_time(:millisecond) - started
      })
    after
      if Process.alive?(projection), do: GenServer.stop(projection)
    end
  end

  defp search_run do
    started = System.monotonic_time(:millisecond)
    threads = create_search_threads!()
    average_bytes = write_search_corpus!(threads)

    {:ok, projection} =
      SearchProjection.start_link(
        root: Paths.search_projection_root(),
        name: nil,
        bootstrap_jobs?: false
      )

    try do
      {:ok, build} = SearchProjection.rebuild("local", projection)

      if build.document_count != @search_messages do
        raise "search benchmark corpus mismatch: #{inspect(build)}"
      end

      queries = search_queries(threads)
      Enum.each(queries, fn {_family, request} -> search_query!(request, projection) end)

      samples =
        Enum.map(queries, fn {family, request} ->
          {family, timed(fn -> search_query!(request, projection) end)}
        end)

      latencies = Enum.map(samples, &elem(&1, 1))
      family_stats = samples |> Enum.group_by(&elem(&1, 0), &elem(&1, 1)) |> summarize_families()

      summarize(latencies)
      |> Map.merge(%{
        consumer: "search",
        messages: @search_messages,
        threads: @search_threads,
        average_document_bytes: average_bytes,
        queries: @search_queries,
        warmup_queries: @search_queries,
        query_families: family_stats,
        p95_limit_ms: 200.0,
        p99_limit_ms: 750.0,
        wall_ms: System.monotonic_time(:millisecond) - started
      })
    after
      if Process.alive?(projection), do: GenServer.stop(projection)
    end
  end

  defp write_memory_corpus do
    directory = Path.join(Memory.root(), "notes")
    File.mkdir_p!(directory)

    Enum.each(0..(@memory_claims - 1), fn index ->
      topic = "scale#{rem(index, @memory_queries)}"
      path = Path.join(directory, "scale-#{String.pad_leading(to_string(index), 5, "0")}.md")
      File.write!(path, memory_entry(topic, index))
    end)
  end

  defp memory_entry(topic, index) do
    """
    # Memory: #{topic} preference #{index}

    - Timestamp: 2026-07-29T10:00:00Z
    - Category: notes
    - Source signal: scale
    - Actor: local
    - Agent: retrieval-scale
    - Channel: test

    ## Body

    #{topic} durable scale fact #{index}

    ## Review

    - Reviewed: 2026-07-29T10:00:00Z
    - Reviewed by: local
    - Status: kept
    - Correction note:
    """
  end

  defp memory_queries, do: Enum.map(0..(@memory_queries - 1), &"scale#{&1} durable")

  defp memory_query!(query, projection) do
    Settings.with_resolved_settings(fn -> memory_query_pinned!(query, projection) end)
  end

  defp memory_query_pinned!(query, projection) do
    {:ok, result} =
      ActiveMemory.retrieve(query,
        user_id: "local",
        now: "2026-07-29T12:00:00Z",
        projection: projection
      )

    topic = query |> String.split() |> hd()

    unless length(result.chunks) == 5 and
             Enum.all?(result.chunks, &String.contains?(&1.body, topic)) do
      raise "memory benchmark query returned an invalid result"
    end
  end

  defp create_search_threads! do
    Enum.map(0..(@search_threads - 1), fn index ->
      {:ok, thread} = Conversations.create_general_thread("local", "Benchmark #{index}")
      thread
    end)
  end

  defp write_search_corpus!(threads) do
    base = ~U[2026-07-29 12:00:00.000000Z]

    rows =
      Enum.map(0..(@search_messages - 1), fn index ->
        thread = Enum.at(threads, rem(index, @search_threads))
        topic = rem(index, 75)
        content = search_content(topic, index)

        %{
          id: "msg-v13-latency-#{String.pad_leading(to_string(index), 5, "0")}",
          thread_id: thread.id,
          user_id: "local",
          role: if(rem(index, 2) == 0, do: "user", else: "assistant"),
          content: content,
          action_log: %{},
          metadata: %{"channel" => if(rem(index, 2) == 0, do: "tui", else: "web")},
          inserted_at: DateTime.add(base, index, :microsecond)
        }
      end)

    count =
      rows
      |> Enum.chunk_every(1_000)
      |> Enum.reduce(0, fn batch, total ->
        {inserted, nil} = Repo.insert_all(Message, batch)
        total + inserted
      end)

    if count != @search_messages do
      raise "search benchmark inserted #{count} messages"
    end

    div(Enum.reduce(rows, 0, &(byte_size(&1.content) + &2)), length(rows))
  end

  defp search_content(topic, index) do
    "topic#{topic} durable benchmark phrase topic#{topic} prefixword#{topic} " <>
      "message #{index} " <> String.duplicate("bounded lexical corpus payload ", 11)
  end

  defp search_queries(threads) do
    terms = Enum.map(0..74, &{:term, %{query: "topic#{&1}", limit: 5}})
    phrases = Enum.map(0..74, &{:phrase, %{query: ~s("topic#{&1} durable"), limit: 5}})
    prefixes = Enum.map(0..74, &{:prefix, %{query: "prefixword#{&1}*", limit: 5}})

    filters =
      Enum.map(0..74, fn index ->
        {:filter,
         %{
           query: "topic#{index}",
           limit: 5,
           filters: %{thread_ids: [Enum.at(threads, index).id]}
         }}
      end)

    terms ++ phrases ++ prefixes ++ filters
  end

  defp search_query!(request, projection) do
    {:ok, page} =
      Search.query(request, %{
        operator_id: "local",
        channel: "cli",
        search_projection: projection
      })

    if page.results == [], do: raise("search benchmark query returned no authorized results")
  end

  defp timed(fun) do
    {microseconds, _result} = :timer.tc(fun)
    microseconds / 1_000
  end

  defp summarize_families(grouped) do
    Map.new(grouped, fn {family, latencies} -> {family, summarize(latencies)} end)
  end

  defp percentile(values, percentile) do
    sorted = Enum.sort(values)
    index = ceil(length(sorted) * percentile) - 1
    Float.round(Enum.at(sorted, index) * 1.0, 3)
  end

  defp corpus_id(:memory), do: "v13-memory-10k-200-v1"
  defp corpus_id(:search), do: "v13-search-25k-300-v1"

  defp parse_consumer!("memory"), do: :memory
  defp parse_consumer!("search"), do: :search
  defp parse_consumer!(other), do: raise("invalid V13 latency consumer: #{inspect(other)}")

  defp format_stats(consumer, stats, status) do
    "v13-latency consumer=#{consumer} status=#{status} samples=#{stats.samples} " <>
      "p95_ms=#{stats.p95_ms} p99_ms=#{stats.p99_ms}"
  end

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp parse_full_sha!(value) when is_binary(value) do
    if value =~ ~r/^[0-9a-f]{40}$/,
      do: value,
      else: raise("V13_FULL_SHA must be a lowercase 40-hex commit")
  end

  defp parse_full_sha!(_value), do: raise("V13_FULL_SHA is required")

  defp parse_dirty!("true"), do: true
  defp parse_dirty!("false"), do: false
  defp parse_dirty!(_value), do: raise("V13_DIRTY must be true or false")
end
