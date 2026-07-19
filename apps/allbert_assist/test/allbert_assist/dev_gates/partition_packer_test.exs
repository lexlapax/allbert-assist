defmodule AllbertAssist.DevGates.PartitionPackerTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.PartitionPacker

  defp file(path, test_count), do: %{path: path, test_count: test_count}

  test "packs heaviest-first onto the lightest bin, deterministically" do
    files = [file("a.exs", 1), file("b.exs", 1), file("c.exs", 1), file("d.exs", 1)]
    costs = %{"a.exs" => 100_000, "b.exs" => 60_000, "c.exs" => 50_000, "d.exs" => 40_000}

    assert [["a.exs"], ["b.exs"], ["c.exs", "d.exs"]] =
             PartitionPacker.pack(files, 3, costs)

    assert PartitionPacker.pack(files, 3, costs) ==
             PartitionPacker.pack(Enum.reverse(files), 3, costs)
  end

  test "every file lands in exactly one bin and bin count is exact" do
    files = for n <- 1..37, do: file("f#{n}.exs", rem(n, 7) + 1)
    costs = Map.new(Enum.take(files, 11), &{&1.path, &1.test_count * 900})

    bins = PartitionPacker.pack(files, 4, costs)

    assert length(bins) == 4
    assert bins |> List.flatten() |> Enum.sort() == files |> Enum.map(& &1.path) |> Enum.sort()
  end

  test "balances measured costs far better than a name split" do
    heavy = for n <- 1..4, do: file("heavy#{n}.exs", 10)
    light = for n <- 1..20, do: file("light#{n}.exs", 2)

    costs =
      Map.new(heavy, &{&1.path, 40_000}) |> Map.merge(Map.new(light, &{&1.path, 1_000}))

    totals =
      PartitionPacker.pack(heavy ++ light, 4, costs)
      |> Enum.map(fn paths -> paths |> Enum.map(&Map.fetch!(costs, &1)) |> Enum.sum() end)

    assert Enum.max(totals) - Enum.min(totals) <= 5_000
  end

  test "unmeasured files are priced from the measured median per-test cost" do
    files = [file("m1.exs", 10), file("m2.exs", 10), file("new.exs", 5)]
    costs = %{"m1.exs" => 10_000, "m2.exs" => 30_000}

    # medians: 1_000 and 3_000 ms/test -> median 3_000; new.exs ~ 15_000
    assert PartitionPacker.expected_cost(file("new.exs", 5), costs, 3_000.0) == 15_000.0
    assert PartitionPacker.median_per_test(files, costs) == 3_000.0
  end

  test "fresh store falls back to the default per-test estimate and floor" do
    assert PartitionPacker.median_per_test([file("x.exs", 3)], %{}) == 400.0
    assert PartitionPacker.expected_cost(file("x.exs", 0), %{}, 400.0) == 100.0
  end

  test "fewer files than bins leaves trailing bins empty" do
    bins = PartitionPacker.pack([file("only.exs", 2)], 4, %{})

    assert [["only.exs"], [], [], []] = bins
  end
end
