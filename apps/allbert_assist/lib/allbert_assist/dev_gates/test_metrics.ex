defmodule AllbertAssist.DevGates.TestMetrics do
  @moduledoc """
  Append-only JSONL metrics store for developer test-gate runs (v1.0.2 M8.1).

  Every gate phase, release step, and serial lane partition VM run appends
  one JSON line to `.test_metrics/runs.jsonl` at the repo root (gitignored).
  Recording is best-effort by contract: any failure while recording is
  rescued and reported as a warning, never raised, so metrics can never
  fail a gate. `mix allbert.test metrics` renders the committed summary
  tables into `docs/validation/test-metrics/summary.md` and can ingest
  seed-campaign logs retroactively.

  This module is development tooling only. It does not grant runtime
  authority and does not participate in Security Central decisions.
  """

  @store_relative ".test_metrics/runs.jsonl"
  @summary_relative "docs/validation/test-metrics/summary.md"
  @campaign_csv "results-pre-optimization.csv"
  # 25 (was 10, v1.0.2 M8.8): deeper --slowest capture feeds the per-file
  # cost model behind PartitionPacker; ranking quality degrades with only
  # the top 10 when serial lanes carry 100+ files.
  @slowest_limit 25
  @gate_table_limit 20
  @slowest_aggregate_limit 50
  @slowest_table_limit 20

  # ExUnit prints one totals line per run; singular ("1 test, 1 failure") and
  # plural forms both occur, so every count/label pair is matched explicitly
  # (the naive plural-only regex undercounted single-test runs).
  @totals_line ~r/^.*\b\d+ tests?, \d+ failures?.*$/m
  @totals_pair ~r/(\d+) (tests?|failures?|excluded|skipped)\b/
  @seed_line ~r/Running ExUnit with seed:\s*(\d+)/
  @slowest_header ~r/^\s*Top \d+ slowest/
  @slowest_entry ~r/^\s*\* (.+) \((\d+(?:\.\d+)?)(ms|s)\) \[([^\]]+)\]\s*$/
  @file_line_location ~r/^(.+\.exs):\d+$/

  @doc """
  Appends one metrics record. Never raises; failures warn and return `:ok`.

  Known keys: `:gate`, `:phase_or_step`, `:lane`, `:partition`,
  `:partitions`, `:wall_ms`, `:status` (`"passed"`/`"failed"`), plus
  optional `:output` (raw gate output — parsed for seed, summed ExUnit
  totals, and the `--slowest` report) and explicit overrides for any
  derived field (`:seed`, `:tests`, `:failures`, `:excluded`, `:skipped`,
  `:slowest`, `:recorded_at`, `:git_sha`). `:store` overrides the store
  path (test seam); `:test_metrics_store` app env overrides it globally.
  """
  def record(attrs) when is_map(attrs) do
    case resolve_store(attrs) do
      :disabled ->
        :ok

      store ->
        line = attrs |> build_record() |> Jason.encode!()
        File.mkdir_p!(Path.dirname(store))
        File.write!(store, line <> "\n", [:append])
        :ok
    end
  rescue
    error ->
      Mix.shell().error(
        "test metrics record skipped (gates unaffected): #{Exception.message(error)}"
      )

      :ok
  end

  @doc "Sums every ExUnit totals line in `output` (singular and plural forms)."
  def sum_exunit_totals(output) when is_binary(output) do
    @totals_line
    |> Regex.scan(output)
    |> Enum.reduce(%{tests: 0, failures: 0, excluded: 0, skipped: 0}, fn [line], acc ->
      @totals_pair
      |> Regex.scan(line)
      |> Enum.reduce(acc, fn [_pair, count, label], acc ->
        Map.update!(acc, totals_key(label), &(&1 + String.to_integer(count)))
      end)
    end)
  end

  @doc "First `Running ExUnit with seed: N` in `output`, or nil."
  def parse_seed(output) when is_binary(output) do
    case Regex.run(@seed_line, output) do
      [_match, seed] -> String.to_integer(seed)
      nil -> nil
    end
  end

  @doc """
  Parses every ExUnit `--slowest` report section in `output` into up to
  #{@slowest_limit} `%{"name" => file:line-or-test-name, "ms" => float}`
  entries, slowest first. Returns `[]` when no report is present.
  """
  def parse_slowest(output) when is_binary(output) do
    output
    |> String.split(~r/\r?\n/)
    |> collect_slowest_sections([])
    |> Enum.sort_by(& &1["ms"], :desc)
    |> Enum.take(@slowest_limit)
  end

  @doc """
  Ingests a seed-campaign directory: each `seed-<N>.log` becomes one
  `"seed-campaign"` record (totals summed from the log, wall clock from
  `#{@campaign_csv}` when present). Returns the ingested record count.
  """
  def ingest_campaign!(dir, opts \\ []) do
    walls = campaign_walls(Path.join(dir, @campaign_csv))

    dir
    |> File.ls!()
    |> Enum.filter(&Regex.match?(~r/^seed-\d+\.log$/, &1))
    |> Enum.sort_by(&seed_from_filename/1)
    |> Enum.map(&ingest_campaign_log!(dir, &1, walls, opts))
    |> length()
  end

  @doc """
  Renders the metrics summary markdown from the store into
  `#{@summary_relative}` (overwriting). Options: `:store`, `:output`.
  Returns the output path.
  """
  def render_summary!(opts \\ []) do
    store = Keyword.get(opts, :store) || readable_store()
    output = Keyword.get(opts, :output, Path.join(repo_root(), @summary_relative))
    records = read_records(store)

    File.mkdir_p!(Path.dirname(output))
    File.write!(output, summary_markdown(records))
    output
  end

  @doc """
  Per-file expected wall (ms) aggregated from recorded `--slowest` reports.

  Within one record a file's cost is the sum of its slowest-test entries;
  the returned map holds each file's average across the records where it
  appeared. Coverage is partial by construction (top-#{@slowest_limit}
  tests per run), so callers must estimate files absent from the map —
  `AllbertAssist.DevGates.PartitionPacker` does.
  """
  def file_costs(opts \\ []) do
    store = Keyword.get(opts, :store) || readable_store()

    store
    |> read_records()
    |> Enum.sort_by(&Map.get(&1, "recorded_at", ""), :desc)
    |> Enum.take(@slowest_aggregate_limit)
    |> Enum.flat_map(fn record ->
      record
      |> Map.get("slowest")
      |> List.wrap()
      |> Enum.group_by(&slowest_file/1)
      |> Enum.map(fn {file, entries} ->
        {file, entries |> Enum.map(&Map.get(&1, "ms", 0)) |> Enum.sum()}
      end)
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {file, sums} -> {file, Enum.sum(sums) / length(sums)} end)
  end

  def default_store_path, do: Path.join(repo_root(), @store_relative)

  def repo_root, do: Path.expand("../../../../..", __DIR__)

  defp resolve_store(attrs) do
    case Map.get(attrs, :store) || Application.get_env(:allbert_assist, :test_metrics_store) do
      nil -> default_store_path()
      :disabled -> :disabled
      path when is_binary(path) -> path
    end
  end

  defp readable_store do
    case Application.get_env(:allbert_assist, :test_metrics_store) do
      path when is_binary(path) -> path
      _other -> default_store_path()
    end
  end

  defp build_record(attrs) do
    output = Map.get(attrs, :output, "")
    totals = sum_exunit_totals(output)

    %{
      recorded_at: Map.get_lazy(attrs, :recorded_at, &utc_now_iso8601/0),
      git_sha: Map.get_lazy(attrs, :git_sha, &cached_git_sha/0),
      gate: Map.get(attrs, :gate),
      phase_or_step: Map.get(attrs, :phase_or_step),
      lane: Map.get(attrs, :lane),
      partition: Map.get(attrs, :partition),
      partitions: Map.get(attrs, :partitions),
      seed: Map.get_lazy(attrs, :seed, fn -> parse_seed(output) end),
      tests: Map.get(attrs, :tests, totals.tests),
      failures: Map.get(attrs, :failures, totals.failures),
      excluded: Map.get(attrs, :excluded, totals.excluded),
      skipped: Map.get(attrs, :skipped, totals.skipped),
      wall_ms: Map.get(attrs, :wall_ms),
      status: Map.get(attrs, :status),
      slowest: Map.get_lazy(attrs, :slowest, fn -> parse_slowest(output) end)
    }
  end

  defp utc_now_iso8601, do: DateTime.utc_now() |> DateTime.to_iso8601()

  # Cached once per VM invocation; serial partitions record from spawned
  # tasks, so the cache lives in :persistent_term rather than the process.
  defp cached_git_sha do
    case :persistent_term.get({__MODULE__, :git_sha}, :unset) do
      :unset ->
        sha = compute_git_sha()
        :persistent_term.put({__MODULE__, :git_sha}, sha)
        sha

      sha ->
        sha
    end
  end

  defp compute_git_sha do
    case System.cmd("git", ["rev-parse", "--short", "HEAD"],
           cd: repo_root(),
           stderr_to_stdout: true
         ) do
      {sha, 0} -> String.trim(sha)
      {_output, _status} -> nil
    end
  rescue
    _error -> nil
  end

  defp totals_key("test" <> _rest), do: :tests
  defp totals_key("failure" <> _rest), do: :failures
  defp totals_key("excluded"), do: :excluded
  defp totals_key("skipped"), do: :skipped

  defp collect_slowest_sections([], acc), do: acc

  defp collect_slowest_sections([line | rest], acc) do
    if Regex.match?(@slowest_header, line) do
      {entries, rest} = take_slowest_entries(rest, [])
      collect_slowest_sections(rest, acc ++ entries)
    else
      collect_slowest_sections(rest, acc)
    end
  end

  defp take_slowest_entries([], acc), do: {Enum.reverse(acc), []}

  defp take_slowest_entries([line | rest] = lines, acc) do
    case slowest_entry(line) do
      nil ->
        if String.trim(line) == "" do
          take_slowest_entries(rest, acc)
        else
          {Enum.reverse(acc), lines}
        end

      entry ->
        take_slowest_entries(rest, [entry | acc])
    end
  end

  defp slowest_entry(line) do
    case Regex.run(@slowest_entry, line) do
      [_match, name, number, unit, location] ->
        {value, _rest} = Float.parse(number)
        ms = if unit == "s", do: value * 1000, else: value
        %{"name" => slowest_name(name, location), "ms" => Float.round(ms, 2)}

      nil ->
        nil
    end
  end

  # Prefer the file:line bracket; per-test trace lines carry `[L#N]` only and
  # never follow a slowest header, but fall back to the test name defensively.
  defp slowest_name(name, location) do
    if Regex.match?(@file_line_location, location), do: location, else: name
  end

  defp ingest_campaign_log!(dir, filename, walls, opts) do
    path = Path.join(dir, filename)
    seed = seed_from_filename(filename)
    output = File.read!(path)
    totals = sum_exunit_totals(output)

    record(%{
      store: Keyword.get(opts, :store),
      recorded_at: file_mtime_iso8601(path),
      git_sha: nil,
      gate: "seed-campaign",
      phase_or_step: "full-suite",
      seed: seed,
      wall_ms: Map.get(walls, seed),
      status: if(totals.failures == 0, do: "passed", else: "failed"),
      output: output
    })
  end

  defp seed_from_filename(filename) do
    [_match, seed] = Regex.run(~r/^seed-(\d+)\.log$/, filename)
    String.to_integer(seed)
  end

  defp file_mtime_iso8601(path) do
    path
    |> File.stat!(time: :posix)
    |> Map.fetch!(:mtime)
    |> DateTime.from_unix!()
    |> DateTime.to_iso8601()
  end

  defp campaign_walls(csv_path) do
    case File.read(csv_path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&campaign_wall_row/1)
        |> Map.new()

      {:error, _reason} ->
        %{}
    end
  end

  defp campaign_wall_row(line) do
    case Regex.run(~r/^(\d+),\d+,(\d+),/, line) do
      [_match, seed, duration_s] ->
        [{String.to_integer(seed), String.to_integer(duration_s) * 1000}]

      nil ->
        []
    end
  end

  defp read_records(store) do
    case File.read(store) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&decode_record/1)

      {:error, _reason} ->
        []
    end
  end

  defp decode_record(line) do
    case Jason.decode(line) do
      {:ok, record} when is_map(record) -> [record]
      _other -> []
    end
  end

  defp summary_markdown(records) do
    newest_first = Enum.sort_by(records, &Map.get(&1, "recorded_at", ""), :desc)

    """
    # Test-Run Metrics Summary

    Generated by `mix allbert.test metrics` from `#{@store_relative}` — do not edit by hand.

    - generated_at: #{utc_now_iso8601()}
    - records: #{length(records)}

    ## Per-Gate Runs

    Latest #{@gate_table_limit} records per gate, newest first.

    #{per_gate_sections(newest_first)}
    ## Per-Lane Wall Clock

    Latest record per gate/lane/partition.

    #{per_lane_table(newest_first)}
    ## Slowest Files

    Aggregated across the latest #{@slowest_aggregate_limit} records carrying `--slowest` data.

    #{slowest_files_table(newest_first)}
    """
  end

  defp per_gate_sections([]), do: "No records yet.\n"

  defp per_gate_sections(newest_first) do
    newest_first
    |> Enum.group_by(&Map.get(&1, "gate"))
    |> Enum.sort_by(fn {gate, _records} -> to_string(gate) end)
    |> Enum.map_join("\n", fn {gate, records} ->
      rows =
        records
        |> Enum.take(@gate_table_limit)
        |> Enum.map_join("\n", fn record ->
          row([
            Map.get(record, "recorded_at"),
            Map.get(record, "git_sha"),
            Map.get(record, "phase_or_step"),
            Map.get(record, "status"),
            Map.get(record, "wall_ms"),
            Map.get(record, "tests"),
            Map.get(record, "failures")
          ])
        end)

      """
      ### gate `#{gate}`

      | recorded_at | git sha | phase/step | status | wall ms | tests | failures |
      |---|---|---|---|---|---|---|
      #{rows}
      """
    end)
  end

  defp per_lane_table(newest_first) do
    rows =
      newest_first
      |> Enum.filter(&Map.get(&1, "lane"))
      |> Enum.group_by(fn record ->
        {Map.get(record, "gate"), Map.get(record, "lane"), Map.get(record, "partition"),
         Map.get(record, "partitions")}
      end)
      |> Enum.map(fn {_key, [latest | _older]} -> latest end)
      |> Enum.sort_by(fn record ->
        {to_string(Map.get(record, "gate")), to_string(Map.get(record, "lane")),
         Map.get(record, "partition")}
      end)
      |> Enum.map_join("\n", fn record ->
        row([
          Map.get(record, "gate"),
          Map.get(record, "lane"),
          "#{Map.get(record, "partition")}/#{Map.get(record, "partitions")}",
          Map.get(record, "recorded_at"),
          Map.get(record, "wall_ms"),
          Map.get(record, "tests"),
          Map.get(record, "status")
        ])
      end)

    case rows do
      "" ->
        "No lane records yet.\n"

      rows ->
        """
        | gate | lane | partition | recorded_at | wall ms | tests | status |
        |---|---|---|---|---|---|---|
        #{rows}
        """
    end
  end

  defp slowest_files_table(newest_first) do
    rows =
      newest_first
      |> Enum.take(@slowest_aggregate_limit)
      |> Enum.flat_map(&List.wrap(Map.get(&1, "slowest")))
      |> Enum.group_by(&slowest_file/1)
      |> Enum.map(fn {file, entries} ->
        total = entries |> Enum.map(&Map.get(&1, "ms", 0)) |> Enum.sum()
        max = entries |> Enum.map(&Map.get(&1, "ms", 0)) |> Enum.max()
        {file, Float.round(total * 1.0, 1), length(entries), max}
      end)
      |> Enum.sort_by(fn {_file, total, _samples, _max} -> total end, :desc)
      |> Enum.take(@slowest_table_limit)
      |> Enum.map_join("\n", fn {file, total, samples, max} ->
        row([file, total, samples, max])
      end)

    case rows do
      "" ->
        "No slowest data recorded yet.\n"

      rows ->
        """
        | file or test | total ms | samples | max ms |
        |---|---|---|---|
        #{rows}
        """
    end
  end

  defp slowest_file(entry) do
    name = to_string(Map.get(entry, "name", "unknown"))

    case Regex.run(@file_line_location, name) do
      [_match, file] -> file
      nil -> name
    end
  end

  defp row(cells) do
    "| " <> Enum.map_join(cells, " | ", &cell/1) <> " |"
  end

  defp cell(nil), do: "-"
  defp cell(value), do: value |> to_string() |> String.replace("|", "\\|")
end
