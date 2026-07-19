defmodule AllbertAssist.DevGates.PartitionPacker do
  @moduledoc """
  Cost-based partition packing for serial test lanes (v1.0.2 M8.8).

  ExUnit's `--partitions` assigns files by name hash, blind to cost; the
  metrics store measured the result on `db_serial` as 39.6/174.7/165.1/52.0 s
  across four partitions — a 174.7 s lane wall against a ~108 s balanced
  ideal, and gate walls are the sum of per-lane max-partitions. This module
  replaces the hash split with a greedy bin-pack over measured per-file
  costs (`TestMetrics.file_costs/0`), estimating unmeasured files from
  their test counts.

  Developer-gate infrastructure only: no runtime authority, no Security
  Central participation, and test selection is unchanged — the same lane
  files run, only their partition assignment moves.
  """

  @minimum_cost_ms 100.0

  @doc """
  Packs `files` into `partitions` lists balanced by expected cost.

  `files` is a list of `%{path: String.t(), test_count: non_neg_integer}`
  with an optional `:owner` atom; `costs` maps a path (as it appears in
  gate output, relative to the owner app cwd) or an owner-qualified
  `"owner:path"` key to measured milliseconds. Owner-carrying files prefer
  their qualified key — output-relative paths can collide across owners
  (v1.0.2 M8.9) — and fall back to the bare path for legacy records.
  Unmeasured files are estimated at `test_count *` the median measured
  per-test cost of this call's measured files (falling back to
  `test_count * 400.0`), floored at #{trunc(@minimum_cost_ms)} ms so
  empty/tiny files still occupy a slot.

  Deterministic: files are seated heaviest-first (ties broken by path) onto
  the lightest bin (ties broken by bin index). Returns exactly `partitions`
  lists; trailing bins may be empty when there are fewer files than bins.
  """
  def pack(files, partitions, costs)
      when is_list(files) and is_integer(partitions) and partitions > 0 and is_map(costs) do
    per_test = median_per_test(files, costs)

    bins = for index <- 1..partitions, do: {0.0, index, []}

    files
    |> Enum.map(&{expected_cost(&1, costs, per_test), &1.path})
    |> Enum.sort_by(fn {cost, path} -> {-cost, path} end)
    |> Enum.reduce(bins, &seat_on_lightest_bin/2)
    |> Enum.sort_by(fn {_total, index, _paths} -> index end)
    |> Enum.map(fn {_total, _index, paths} -> Enum.reverse(paths) end)
  end

  @doc "Expected cost (ms) for one file — measured when present, estimated otherwise."
  def expected_cost(%{test_count: test_count} = file, costs, per_test_ms) do
    case fetch_cost(costs, file) do
      {:ok, measured} -> max(measured * 1.0, @minimum_cost_ms)
      :error -> max(test_count * per_test_ms, @minimum_cost_ms)
    end
  end

  @doc """
  Median measured per-test cost across the measured subset of `files`,
  used to price unmeasured files. Falls back to 400.0 ms when nothing in
  `files` has been measured yet (fresh store).
  """
  def median_per_test(files, costs) do
    samples =
      for %{test_count: test_count} = file <- files,
          test_count > 0,
          {:ok, measured} <- [fetch_cost(costs, file)] do
        measured / test_count
      end

    case Enum.sort(samples) do
      [] -> 400.0
      sorted -> Enum.at(sorted, div(length(sorted), 2)) * 1.0
    end
  end

  # M8.9: cost keys are gate-output-relative paths that two owners can
  # share; an owner-carrying file prefers its "owner:path" key and falls
  # back to the bare path so legacy records (no owner field) keep pricing.
  defp fetch_cost(costs, %{path: path} = file) do
    case Map.get(file, :owner) do
      nil ->
        Map.fetch(costs, path)

      owner ->
        with :error <- Map.fetch(costs, "#{owner}:#{path}") do
          Map.fetch(costs, path)
        end
    end
  end

  defp seat_on_lightest_bin({cost, path}, bins) do
    {_total, index, _paths} = Enum.min_by(bins, fn {total, index, _paths} -> {total, index} end)

    Enum.map(bins, fn
      {total, ^index, paths} -> {total + cost, index, [path | paths]}
      bin -> bin
    end)
  end
end
