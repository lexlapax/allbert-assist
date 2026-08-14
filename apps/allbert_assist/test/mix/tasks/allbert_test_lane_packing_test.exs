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
      record("apps/stocksage/test/a_test.exs", :stocksage, :external_runtime_serial, "", 1)
    ]

    core_files = AllbertTestTask.lane_packing_files(records, :core, :external_runtime_serial)

    stocksage_files =
      AllbertTestTask.lane_packing_files(records, :stocksage, :external_runtime_serial)

    assert Enum.map(core_files, &{&1.owner, &1.path}) == [{:core, "test/a_test.exs"}]

    # v1.4 M13 made stocksage a real pack app with its own cwd (apps/stocksage),
    # the same shape every other extracted pack has -- so its record relativizes
    # to "test/a_test.exs" exactly like core's, the identical bare filename the
    # M8.9 cost-key comment above (record_serial_partition_metrics) anticipated:
    # "two owners can share an output-relative path". The leak this test guards
    # against is proven by each owner's query returning exactly one entry --
    # never the other owner's record -- not by the path strings differing.
    assert [{:stocksage, stocksage_path}] = Enum.map(stocksage_files, &{&1.owner, &1.path})
    assert stocksage_path == "test/a_test.exs"
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

  test "inventory includes every first-party plugin test owner exactly once" do
    records = AllbertTestTask.inventory_records()
    by_path = Map.new(records, &{&1.path, &1})

    assert %{
             owner: :artifacts,
             primary_lane: :db_serial
           } =
             by_path[
               "apps/allbert_artifacts/test/allbert_artifacts/app_panels_test.exs"
             ]

    assert %{
             owner: :artifacts,
             primary_lane: :db_serial
           } =
             by_path[
               "apps/allbert_artifacts/test/mix/tasks/allbert_artifacts_test.exs"
             ]

    assert %{
             owner: :notes_files,
             primary_lane: :pure_async
           } =
             by_path[
               "apps/allbert_notes_files/test/allbert_notes_files/intent_descriptors_test.exs"
             ]

    # M1.a3 added artifact_live_readiness_test.exs as a fourth artifacts-owned
    # file (946052384) without updating this count. Anchor the new file to its
    # owner and lane so the number is not the only thing holding the assertion.
    assert %{
             owner: :artifacts,
             primary_lane: :pure_async
           } =
             by_path[
               "apps/allbert_artifacts/test/allbert_artifacts_web/artifact_live_readiness_test.exs"
             ]

    # v1.4 M12 moved the notes CLI area into the pack alongside its Mix task, so
    # notes_files owns a fourth file. Anchored to its owner and lane for the same
    # reason the artifacts row above is: a bare count tells the next person a
    # number changed, not which file moved or where it landed.
    assert %{
             owner: :notes_files,
             primary_lane: :app_env_serial
           } =
             by_path[
               "apps/allbert_notes_files/test/allbert_notes_files/cli_test.exs"
             ]

    # M12 also made telegram and email pack owners in their own right. Their
    # suites kept the lanes they had under plugins/; what changed is the owner
    # that answers for them, which is exactly what this test exists to pin.
    assert %{owner: :telegram, primary_lane: :external_runtime_serial} =
             by_path["apps/allbert_telegram/test/edit_test.exs"]

    assert %{owner: :telegram, primary_lane: :db_serial} =
             by_path["apps/allbert_telegram/test/renderer_test.exs"]

    assert %{owner: :email, primary_lane: :db_serial} =
             by_path["apps/allbert_email/test/renderer_test.exs"]

    assert Enum.count(records, &(&1.owner == :artifacts)) == 4
    assert Enum.count(records, &(&1.owner == :notes_files)) == 4
    assert Enum.count(records, &(&1.owner == :telegram)) == 2
    assert Enum.count(records, &(&1.owner == :email)) == 1
    assert AllbertTestTask.lane_reconciliation_issues(records) == []
  end

  test "resource classification distinguishes Report from Repo and retains audited owners" do
    records = Map.new(AllbertTestTask.inventory_records(), &{&1.path, &1.primary_lane})

    assert records[
             "apps/allbert_assist/test/allbert_assist/objectives/canonical_json_test.exs"
           ] == :pure_async

    assert records[
             "apps/allbert_assist/test/allbert_assist/objectives/report_synthesis_agent_test.exs"
           ] == :pure_async

    assert records["apps/allbert_tui/test/allbert_assist/cli/tui_test.exs"] ==
             :app_env_serial

    assert records["apps/allbert_assist/test/mix/tasks/allbert_dispatcher_test.exs"] ==
             :external_runtime_serial

    assert records[
             "apps/allbert_assist/test/allbert_assist/actions/intent/direct_answer_test.exs"
           ] == :app_env_serial

    assert records["apps/allbert_assist/test/allbert_assist/runtime/trace_test.exs"] ==
             :app_env_serial

    assert records["apps/allbert_assist/test/allbert_assist/cli/commands_test.exs"] ==
             :global_process_serial
  end
end
