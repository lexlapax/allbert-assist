defmodule AllbertAssist.DevGates.OwnerQualifiedCostsTest do
  @moduledoc """
  v1.0.2 M8.9 — owner-qualified packer cost keys: qualified lookups win
  over colliding bare paths, legacy bare-path records keep pricing, and
  file_costs emits qualified keys for owner-carrying records.
  """
  use ExUnit.Case, async: false

  @moduletag :home_fs_serial

  alias AllbertAssist.DevGates.PartitionPacker
  alias AllbertAssist.DevGates.TestMetrics

  test "expected_cost prefers the owner-qualified key and falls back to the bare path" do
    costs = %{"core:test/shared_test.exs" => 50_000.0, "test/shared_test.exs" => 2_000.0}

    assert PartitionPacker.expected_cost(
             %{path: "test/shared_test.exs", test_count: 1, owner: :core},
             costs,
             400.0
           ) == 50_000.0

    # A different owner sharing the relative path must not read core's cost;
    # it falls back to the legacy bare-path measurement.
    assert PartitionPacker.expected_cost(
             %{path: "test/shared_test.exs", test_count: 1, owner: :stocksage},
             costs,
             400.0
           ) == 2_000.0

    # Owner-less files (legacy callers) keep bare-path behavior.
    assert PartitionPacker.expected_cost(
             %{path: "test/shared_test.exs", test_count: 1},
             costs,
             400.0
           ) == 2_000.0
  end

  test "median_per_test measures through owner-qualified keys" do
    files = [
      %{path: "test/a_test.exs", test_count: 10, owner: :core},
      %{path: "test/b_test.exs", test_count: 10, owner: :core}
    ]

    costs = %{"core:test/a_test.exs" => 10_000.0, "core:test/b_test.exs" => 30_000.0}

    assert PartitionPacker.median_per_test(files, costs) == 3_000.0
  end

  test "pack seats files by their owner's measured cost, not a colliding qualified key" do
    files = [
      %{path: "test/shared_test.exs", test_count: 1, owner: :stocksage},
      %{path: "test/other_test.exs", test_count: 1, owner: :stocksage}
    ]

    costs = %{
      # core's heavy measurement of the same relative path must not drag
      # the stocksage copy onto its own bin ahead of the real heavy file.
      "core:test/shared_test.exs" => 90_000.0,
      "stocksage:test/shared_test.exs" => 1_000.0,
      "stocksage:test/other_test.exs" => 50_000.0
    }

    assert PartitionPacker.pack(files, 2, costs) ==
             [["test/other_test.exs"], ["test/shared_test.exs"]]
  end

  test "file_costs qualifies keys for owner-carrying records and keeps legacy bare keys" do
    store = Path.join(owned_dir(), "runs.jsonl")

    assert :ok =
             TestMetrics.record(%{
               store: store,
               gate: "serial-core",
               owner: "core",
               git_sha: nil,
               recorded_at: "2026-07-19T00:00:00Z",
               status: "passed",
               slowest: [%{"name" => "test/shared_test.exs:10", "ms" => 1200.0}]
             })

    # Legacy record shape: no owner field -> bare-path cost key.
    assert :ok =
             TestMetrics.record(%{
               store: store,
               gate: "serial-core",
               git_sha: nil,
               recorded_at: "2026-07-19T00:00:01Z",
               status: "passed",
               slowest: [%{"name" => "test/shared_test.exs:10", "ms" => 400.0}]
             })

    costs = TestMetrics.file_costs(store: store)

    assert costs["core:test/shared_test.exs"] == 1200.0
    assert costs["test/shared_test.exs"] == 400.0
  end

  defp owned_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "allbert-owner-costs-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end
end
