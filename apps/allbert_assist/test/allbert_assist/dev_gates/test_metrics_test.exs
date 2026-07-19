defmodule AllbertAssist.DevGates.TestMetricsTest do
  @moduledoc """
  v1.0.2 M8.1 — the test-run metrics substrate: summed ExUnit totals
  (singular and plural), seed and --slowest parsing, the record-never-raises
  contract, campaign ingestion, and the rendered summary report.
  """
  use ExUnit.Case, async: false
  @moduletag :home_fs_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.DevGates.TestMetrics

  @sample_output """
  Running ExUnit with seed: 4242, max_cases: 1

  ..........

  Finished in 12.3 seconds (0.1s async, 12.2s sync)

  Top 3 slowest (2.10s), 17.0% of total time:

    * test slow write path (AllbertAssist.SomeTest) (1200.5ms) [test/allbert_assist/some_test.exs:12]
    * test slower boot (AllbertAssist.OtherTest) (1.4s) [test/allbert_assist/other_test.exs:34]
    * test named without a file location (AllbertAssist.OtherTest) (300.0ms) [L#7]

  1 test, 1 failure, 1 excluded, 1 skipped

  Running ExUnit with seed: 99, max_cases: 1
  12 tests, 0 failures, 3 excluded, 2 skipped
  """

  describe "sum_exunit_totals/1" do
    test "sums every totals line, singular and plural forms alike" do
      assert TestMetrics.sum_exunit_totals(@sample_output) == %{
               tests: 13,
               failures: 1,
               excluded: 4,
               skipped: 3
             }
    end

    test "handles the bare singular pair and outputs without totals" do
      assert TestMetrics.sum_exunit_totals("1 test, 1 failure\n") == %{
               tests: 1,
               failures: 1,
               excluded: 0,
               skipped: 0
             }

      assert TestMetrics.sum_exunit_totals("no totals here") == %{
               tests: 0,
               failures: 0,
               excluded: 0,
               skipped: 0
             }
    end
  end

  describe "parse_seed/1" do
    test "reads the first ExUnit seed line and nil when absent" do
      assert TestMetrics.parse_seed(@sample_output) == 4242
      assert TestMetrics.parse_seed("no seed printed") == nil
    end
  end

  describe "parse_slowest/1" do
    test "parses file:line entries, seconds units, and name-only fallbacks" do
      assert [
               %{"name" => "test/allbert_assist/other_test.exs:34", "ms" => 1400.0},
               %{"name" => "test/allbert_assist/some_test.exs:12", "ms" => 1200.5},
               %{"name" => "test named without a file location" <> _rest, "ms" => 300.0}
               | _rest_entries
             ] = TestMetrics.parse_slowest(@sample_output <> extra_slowest_section())

      assert TestMetrics.parse_slowest("no report") == []
    end

    test "caps merged sections at ten entries, slowest first" do
      entries = TestMetrics.parse_slowest(@sample_output <> extra_slowest_section())
      assert length(entries) <= 10
      assert entries == Enum.sort_by(entries, & &1["ms"], :desc)
    end
  end

  describe "record/1" do
    test "appends one JSON line with parsed output fields" do
      store = temp_store()
      on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

      assert :ok =
               TestMetrics.record(%{
                 store: store,
                 gate: "fast-local",
                 phase_or_step: "serial-db_serial",
                 lane: "db_serial",
                 partition: 1,
                 partitions: 4,
                 status: "passed",
                 wall_ms: 1234,
                 output: @sample_output
               })

      assert [record] = read_store(store)
      assert record["gate"] == "fast-local"
      assert record["lane"] == "db_serial"
      assert record["seed"] == 4242
      assert record["tests"] == 13
      assert record["failures"] == 1
      assert record["excluded"] == 4
      assert record["skipped"] == 3
      assert record["wall_ms"] == 1234
      assert record["status"] == "passed"
      assert is_binary(record["recorded_at"])
      assert [%{"ms" => 1400.0} | _rest] = record["slowest"]
    end

    test "never raises: an unwritable store warns and returns :ok" do
      blocker =
        Path.join(
          System.tmp_dir!(),
          "metrics-blocker-#{System.pid()}-#{System.unique_integer([:positive])}"
        )

      File.write!(blocker, "not a directory")
      on_exit(fn -> File.rm_rf!(blocker) end)

      warning =
        capture_io(:stderr, fn ->
          assert :ok =
                   TestMetrics.record(%{
                     store: Path.join([blocker, "nested", "runs.jsonl"]),
                     gate: "fast-local",
                     status: "passed"
                   })
        end)

      assert warning =~ "test metrics record skipped (gates unaffected)"
    end
  end

  describe "ingest_campaign!/2" do
    test "ingests seed logs with csv wall clock into seed-campaign records" do
      dir = temp_dir()
      store = temp_store()

      on_exit(fn ->
        File.rm_rf!(dir)
        File.rm_rf!(Path.dirname(store))
      end)

      File.write!(Path.join(dir, "seed-1000.log"), """
      Running ExUnit with seed: 1000, max_cases: 40
      2638 tests, 1 failure, 12 skipped
      Running ExUnit with seed: 1000, max_cases: 40
      293 tests, 1 failure
      """)

      File.write!(Path.join(dir, "seed-2000.log"), """
      Running ExUnit with seed: 2000, max_cases: 40
      2931 tests, 0 failures
      """)

      File.write!(Path.join(dir, "results-pre-optimization.csv"), """
      seed,exit,duration_s,failures
      1000,2,6059,0
      2000,0,6099,0
      """)

      assert TestMetrics.ingest_campaign!(dir, store: store) == 2
      assert [first, second] = read_store(store)

      assert first["gate"] == "seed-campaign"
      assert first["phase_or_step"] == "full-suite"
      assert first["seed"] == 1000
      assert first["tests"] == 2931
      assert first["failures"] == 2
      assert first["skipped"] == 12
      assert first["wall_ms"] == 6_059_000
      assert first["status"] == "failed"
      assert first["git_sha"] == nil
      assert first["slowest"] == []

      assert second["seed"] == 2000
      assert second["wall_ms"] == 6_099_000
      assert second["status"] == "passed"
    end
  end

  describe "render_summary!/1" do
    test "renders per-gate, per-lane, and slowest-files tables from the store" do
      store = temp_store()
      output = Path.join(Path.dirname(store), "summary.md")
      on_exit(fn -> File.rm_rf!(Path.dirname(store)) end)

      :ok =
        TestMetrics.record(%{
          store: store,
          gate: "fast-local",
          phase_or_step: "serial-db_serial",
          lane: "db_serial",
          partition: 1,
          partitions: 4,
          status: "passed",
          wall_ms: 2000,
          output: @sample_output
        })

      :ok =
        TestMetrics.record(%{
          store: store,
          gate: "release.v102",
          phase_or_step: "v102_lane_reconciliation",
          status: "passed",
          wall_ms: 500,
          output: "142 tests, 0 failures\n"
        })

      path = TestMetrics.render_summary!(store: store, output: output)
      assert path == output
      summary = File.read!(output)

      assert summary =~ "# Test-Run Metrics Summary"
      assert summary =~ "## Per-Gate Runs"
      assert summary =~ "### gate `fast-local`"
      assert summary =~ "### gate `release.v102`"
      assert summary =~ "## Per-Lane Wall Clock"
      assert summary =~ "| fast-local | db_serial | 1/4 |"
      assert summary =~ "## Slowest Files"
      assert summary =~ "test/allbert_assist/other_test.exs"
      assert summary =~ "v102_lane_reconciliation"
    end

    test "renders an empty-store summary without raising" do
      dir = temp_dir()
      on_exit(fn -> File.rm_rf!(dir) end)
      output = Path.join(dir, "summary.md")

      TestMetrics.render_summary!(store: Path.join(dir, "missing.jsonl"), output: output)

      summary = File.read!(output)
      assert summary =~ "No records yet."
      assert summary =~ "No lane records yet."
      assert summary =~ "No slowest data recorded yet."
    end
  end

  defp extra_slowest_section do
    entries =
      Enum.map_join(1..9, "\n", fn index ->
        "  * test filler #{index} (AllbertAssist.FillerTest) " <>
          "(#{index}0.0ms) [test/allbert_assist/filler_test.exs:#{index}]"
      end)

    """

    Top 9 slowest (0.45s), 3.0% of total time:

    #{entries}

    9 tests, 0 failures
    """
  end

  defp temp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "test-metrics-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    dir
  end

  defp temp_store, do: Path.join(temp_dir(), "runs.jsonl")

  defp read_store(store) do
    store
    |> File.read!()
    |> String.split("\n", trim: true)
    |> Enum.map(&Jason.decode!/1)
  end
end
