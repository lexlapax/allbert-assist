defmodule Mix.Tasks.Allbert.TestLanePackingTest do
  @moduledoc """
  v1.0.2 M8.9 — any-tag-level lane inclusion in packed lane lists,
  exact-once partition assignment, owner scoping, empty-partition shape,
  and the real-tree manifest multiplicity facts.
  """
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.PartitionPacker
  alias Mix.Tasks.Allbert.Test, as: AllbertTestTask

  @onboarding "test/allbert_assist/cli/areas/onboarding_test.exs"
  @core_serial_lanes [:db_serial, :app_env_serial, :home_fs_serial, :global_process_serial]

  defp record(path, owner, lane, tags, test_count) do
    %{path: path, owner: owner, primary_lane: lane, tags: tags, test_count: test_count}
  end

  test "describe-level lane tag folds the file into that lane's packed list (590 restore)" do
    [external] = AllbertTestTask.packed_lane_paths(:core, :external_runtime_serial, 1)
    [app_env] = AllbertTestTask.packed_lane_paths(:core, :app_env_serial, 1)

    # The dual-lane onboarding file must appear in BOTH lanes: `--only`
    # filters inside each VM, so the describetag block runs in the external
    # lane and the rest of the file runs in its primary app_env lane.
    assert @onboarding in external
    assert @onboarding in app_env
  end

  test "describe- and test-level lane tags include files beyond their primary lane" do
    records = [
      record(
        "apps/allbert_assist/test/a_test.exs",
        :core,
        :app_env_serial,
        ":app_env_serial; :external_runtime_serial",
        3
      ),
      record("apps/allbert_assist/test/b_test.exs", :core, :db_serial, ":db_serial", 2),
      record("apps/allbert_assist/test/c_test.exs", :core, :pure_async, ":pure_async", 4)
    ]

    files = AllbertTestTask.lane_packing_files(records, :core, :external_runtime_serial)

    assert Enum.map(files, & &1.path) == ["test/a_test.exs"]

    assert AllbertTestTask.lane_packing_files(records, :core, :db_serial)
           |> Enum.map(& &1.path) == ["test/b_test.exs"]
  end

  test "lane packing never leaks across owners, even for a shared bare filename" do
    records = [
      record("apps/allbert_assist/test/a_test.exs", :core, :external_runtime_serial, "", 3),
      record("plugins/stocksage/test/a_test.exs", :stocksage, :external_runtime_serial, "", 1)
    ]

    core_files = AllbertTestTask.lane_packing_files(records, :core, :external_runtime_serial)

    stocksage_files =
      AllbertTestTask.lane_packing_files(records, :stocksage, :external_runtime_serial)

    assert Enum.map(core_files, &{&1.owner, &1.path}) == [{:core, "test/a_test.exs"}]

    # Plugin paths resolve outside the core app cwd, so the shared bare
    # filename can never alias the core file's path or cost key.
    assert [{:stocksage, stocksage_path}] = Enum.map(stocksage_files, &{&1.owner, &1.path})
    assert String.ends_with?(stocksage_path, "plugins/stocksage/test/a_test.exs")
    refute stocksage_path == "test/a_test.exs"
  end

  test "every core-lane file lands in exactly one partition of its lane" do
    records = AllbertTestTask.inventory_records()

    for lane <- @core_serial_lanes do
      bins = AllbertTestTask.packed_lane_paths(:core, lane, 4)
      assert length(bins) == 4

      flat = List.flatten(bins)
      assert flat == Enum.uniq(flat)

      expected =
        records
        |> AllbertTestTask.lane_packing_files(:core, lane)
        |> Enum.map(& &1.path)

      assert Enum.sort(flat) == Enum.sort(expected)
    end
  end

  test "empty lanes and lanes smaller than the partition count keep the bin shape" do
    assert AllbertTestTask.lane_packing_files([], :core, :db_serial) == []
    assert PartitionPacker.pack([], 3, %{}) == [[], [], []]

    files = [%{path: "test/a_test.exs", test_count: 2, owner: :core}]
    assert PartitionPacker.pack(files, 4, %{}) == [["test/a_test.exs"], [], [], []]
  end

  test "real-tree manifest records the intentional dual-lane tests" do
    rows = AllbertTestTask.inventory_records() |> AllbertTestTask.manifest_rows()
    dual = Enum.filter(rows, &(&1.multiplicity > 1))

    assert length(dual) == 3

    for row <- dual do
      assert row.path == "apps/allbert_assist/#{@onboarding}"
      assert row.describe == "v0.63 M6 --authorize pre-authorization"
      assert row.multiplicity == 2
      assert row.lane_tags == "module:app_env_serial; describe:external_runtime_serial"
    end
  end
end
