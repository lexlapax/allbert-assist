defmodule AllbertAssist.DevGates.DecideBench do
  @corpus_id "decide-v1"
  @rounds 3

  # Corpus v1 — the M8.8 profiling protocol's 10 prompts, verbatim
  # (formerly the `decide_profile.exs` scratchpad). Changing a prompt is a
  # new corpus: bump the id, never mutate "decide-v1".
  @corpus_v1 [
    "tell me a tiny joke",
    "summarize https://example.com/article for me",
    "what channels are configured?",
    "remind me to water the plants tomorrow at 9",
    "search my notes for the phoenix upgrade checklist",
    "what's in my portfolio today?",
    "turn on dark mode",
    "draft an email to sam about the offsite",
    "how do I connect telegram?",
    "continue the research objective"
  ]

  @moduledoc """
  Structured `Engine.decide/1` corpus benchmark (v1.0.2 M8.10).

  Promotes the M8.8 decide-turn profiling protocol to a first-class
  dev-gates runner: corpus `#{@corpus_id}` is the 10-prompt list below run
  as one warmup pass followed by #{@rounds} timed rounds (`:timer.tc`
  around `AllbertAssist.Intent.Engine.decide/1` on
  `AllbertAssist.Intent.EvalFixtures.request/1`). Each run records exactly
  ONE provenance-carrying row in the test-metrics store (`gate`
  `"bench-decide"`, `corpus_id` `"#{@corpus_id}"`, wall stats
  mean/p50/max ms) so pre/post performance claims can cite
  identical-command structured records instead of scratchpad output.

  Invoked via `mix allbert.test bench-decide`, which boots the test env in
  an owned gate home (migrate first) and calls `record_run!/0` in the
  child VM. Tests seam the per-prompt runner (`:turn`) and the store
  (`:store`); the real benchmark never runs inside the test suite.

  This module is development tooling only. It does not grant runtime
  authority and does not participate in Security Central decisions.
  """

  alias AllbertAssist.DevGates.TestMetrics
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures

  def corpus_id, do: @corpus_id
  def corpus_v1, do: @corpus_v1

  @doc """
  Runs corpus #{@corpus_id} (one warmup pass, then #{@rounds} timed
  rounds), records one store row, and returns the stats map
  (`:turns`/`:mean_ms`/`:p50_ms`/`:max_ms`).

  Options: `:turn` (per-prompt runner returning wall ms — test seam;
  defaults to the real timed `Engine.decide/1` turn) and `:store`
  (test-metrics store path — test seam).
  """
  def run(opts \\ []) do
    turn = Keyword.get(opts, :turn, &decide_turn/1)
    started = System.monotonic_time(:millisecond)

    # Warmup pass: exercised but never timed into the stats (protocol parity
    # with the M8.8 scratchpad).
    Enum.each(@corpus_v1, turn)

    walls = for _round <- 1..@rounds, text <- @corpus_v1, do: turn.(text)
    wall_ms = System.monotonic_time(:millisecond) - started
    stats = stats(walls)

    TestMetrics.record(%{
      store: Keyword.get(opts, :store),
      gate: "bench-decide",
      phase_or_step: "corpus",
      corpus_id: @corpus_id,
      command: "bench-decide",
      status: "passed",
      wall_ms: wall_ms,
      stats: stats
    })

    stats
  end

  @doc "Child-VM entry point for `mix allbert.test bench-decide`: run, print, `:ok`."
  def record_run! do
    stats = run()
    IO.puts(format_stats(stats))
    :ok
  end

  @doc "Wall stats over the timed walls: protocol mean/p50/max, rounded to 0.1 ms."
  def stats(walls) do
    sorted = Enum.sort(walls)

    %{
      turns: length(walls),
      mean_ms: Float.round(Enum.sum(walls) / length(walls), 1),
      p50_ms: Float.round(Enum.at(sorted, div(length(sorted), 2)) * 1.0, 1),
      max_ms: Float.round(Enum.max(walls) * 1.0, 1)
    }
  end

  @doc "One printable stats line for the gate output."
  def format_stats(stats) do
    "bench-decide corpus=#{@corpus_id} turns=#{stats.turns} " <>
      "mean_ms=#{stats.mean_ms} p50_ms=#{stats.p50_ms} max_ms=#{stats.max_ms}"
  end

  defp decide_turn(text) do
    request = EvalFixtures.request(text: text)
    {us, _result} = :timer.tc(fn -> Engine.decide(request) end)
    us / 1000
  end
end
