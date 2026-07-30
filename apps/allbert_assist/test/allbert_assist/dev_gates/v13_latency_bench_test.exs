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

  test "the real runner owns exact LD 82 scales and a complete warm pass" do
    source =
      Path.expand("../../../lib/allbert_assist/dev_gates/v13_latency_bench.ex", __DIR__)
      |> File.read!()

    assert source =~ "@memory_claims 10_000"
    assert source =~ "@memory_queries 200"
    assert source =~ "@search_messages 25_000"
    assert source =~ "@search_threads 250"
    assert source =~ "@search_queries 300"
    assert source =~ "Enum.each(queries"
    assert source =~ ~s(gate: "bench-v13-latency")

    search_source =
      Path.expand("../../../lib/allbert_assist/search.ex", __DIR__)
      |> File.read!()

    assert search_source =~ "Settings.with_resolved_settings(fn ->"
  end
end
