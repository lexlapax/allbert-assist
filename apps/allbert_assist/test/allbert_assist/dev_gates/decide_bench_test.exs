defmodule AllbertAssist.DevGates.DecideBenchTest do
  @moduledoc """
  v1.0.2 M8.10 — the corpus-v1 decide benchmark runner: corpus contents,
  protocol shape (one warmup pass + three timed rounds), stats math, and
  the single provenance-carrying store row. The per-prompt runner is
  seamed (`:turn`); the real `Engine.decide` benchmark never runs here.
  """
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.DecideBench

  test "corpus v1 embeds the 10 M8.8 protocol prompts verbatim" do
    corpus = DecideBench.corpus_v1()

    assert corpus == [
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

    assert DecideBench.corpus_id() == "decide-v1"
  end

  test "run/1 warms one pass, times three rounds, and records one provenance row" do
    store = temp_store()
    on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)
    parent = self()

    turn = fn text ->
      send(parent, {:turn, text})
      5.0
    end

    stats = DecideBench.run(store: store, turn: turn)

    # 1 warmup pass + 3 timed rounds = 4 traversals of the 10-prompt corpus
    prompts = collect_turns()
    assert length(prompts) == 40
    assert Enum.take(prompts, 10) == DecideBench.corpus_v1()

    # warmup is exercised but never timed into the stats
    assert stats == %{turns: 30, mean_ms: 5.0, p50_ms: 5.0, max_ms: 5.0}

    assert [record] = read_store(store)
    assert record["gate"] == "bench-decide"
    assert record["phase_or_step"] == "corpus"
    assert record["corpus_id"] == "decide-v1"
    assert record["command"] == "bench-decide"
    assert record["status"] == "passed"
    assert is_integer(record["wall_ms"])

    assert record["stats"] == %{
             "turns" => 30,
             "mean_ms" => 5.0,
             "p50_ms" => 5.0,
             "max_ms" => 5.0
           }

    # provenance defaults populate: a bench row is never LEGACY
    assert record["full_sha"] =~ ~r/^[0-9a-f]{40}$/
    assert is_boolean(record["dirty"])
    assert is_binary(record["cwd"])
    assert is_binary(record["host_class"])
  end

  test "stats/1 computes mean, the protocol p50 index, and max over the walls" do
    assert DecideBench.stats([1.0, 2.0, 3.0, 10.0]) == %{
             turns: 4,
             mean_ms: 4.0,
             p50_ms: 3.0,
             max_ms: 10.0
           }
  end

  test "format_stats/1 prints the corpus id and the three wall stats" do
    line = DecideBench.format_stats(%{turns: 30, mean_ms: 548.8, p50_ms: 456.7, max_ms: 901.2})

    assert line ==
             "bench-decide corpus=decide-v1 turns=30 mean_ms=548.8 p50_ms=456.7 max_ms=901.2"
  end

  defp collect_turns(acc \\ []) do
    receive do
      {:turn, text} -> collect_turns([text | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp temp_store do
    dir =
      Path.join(
        System.tmp_dir!(),
        "decide-bench-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    Path.join(dir, "runs.jsonl")
  end

  defp read_store(store) do
    store
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
