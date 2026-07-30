defmodule AllbertAssist.DevGates.V13LatencyBenchTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.V13LatencyBench

  test "summarizes nearest-rank p95/p99 and enforces each frozen bound" do
    values = Enum.map(1..100, &(&1 * 1.0))

    assert %{samples: 100, p95_ms: 95.0, p99_ms: 99.0} =
             V13LatencyBench.summarize(values)

    assert V13LatencyBench.within_bound?(:memory, %{p95_ms: 75.0, p99_ms: 250.0})
    refute V13LatencyBench.within_bound?(:memory, %{p95_ms: 75.001, p99_ms: 250.0})
    assert V13LatencyBench.within_bound?(:search, %{p95_ms: 200.0, p99_ms: 750.0})
    refute V13LatencyBench.within_bound?(:search, %{p95_ms: 200.0, p99_ms: 750.001})
  end

  test "the runner exposes the exact LD 82 protocols it uses for recorded rows" do
    assert %{
             corpus_id: "v13-memory-10k-200-v1",
             claims: 10_000,
             queries: 200,
             warmup_queries: 200,
             top_k: 5,
             p95_limit_ms: 75.0,
             p99_limit_ms: 250.0
           } = V13LatencyBench.protocol(:memory)

    assert %{
             corpus_id: "v13-search-25k-300-v1",
             messages: 25_000,
             threads: 250,
             queries: 300,
             warmup_queries: 300,
             p95_limit_ms: 200.0,
             p99_limit_ms: 750.0
           } = V13LatencyBench.protocol(:search)
  end
end
