defmodule AllbertAssist.DevGates.TestManifestTest do
  @moduledoc """
  v1.0.2 M8.9 — per-test manifest parsing (module/describe/test tag levels,
  skip tags, execution multiplicity) and the emit/check drift round-trip on
  the manifest_fixture.exs source.
  """
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.DevGates.TestManifest

  @lanes [:pure_async, :db_serial, :app_env_serial, :external_runtime_serial]
  @record %{path: "manifest_fixture.exs", owner: :core, primary_lane: :app_env_serial}

  defp fixture_rows do
    TestManifest.rows([@record], __DIR__, @lanes)
  end

  test "one row per test/property with module, describe context, and source order" do
    rows = fixture_rows()

    assert Enum.map(rows, &{&1.kind, &1.describe, &1.name}) == [
             {"test", "", "module lane only"},
             {"test", "dual-lane block", "first dual-lane"},
             {"property", "dual-lane block", "second dual-lane"},
             {"test", "tagged block", "test-level lane and skip"},
             {"test", "tagged block", "untagged neighbor keeps multiplicity one"},
             {"test", "", "after describe returns to module scope"}
           ]

    assert Enum.all?(rows, &(&1.module == "AllbertAssist.DevGates.ManifestFixture"))
    assert Enum.all?(rows, &(&1.owner == :core))
    assert Enum.all?(rows, &(&1.primary_lane == "app_env_serial"))
  end

  test "lane tags carry their level and set the expected execution multiplicity" do
    rows = fixture_rows()
    by_name = Map.new(rows, &{&1.name, &1})

    assert by_name["module lane only"].lane_tags == "module:app_env_serial"
    assert by_name["module lane only"].multiplicity == 1

    # The dual-lane describetag block is the operator-preserved shape:
    # both lanes select these tests, so they execute twice.
    for name <- ["first dual-lane", "second dual-lane"] do
      assert by_name[name].lane_tags ==
               "module:app_env_serial; describe:external_runtime_serial"

      assert by_name[name].multiplicity == 2
    end

    assert by_name["test-level lane and skip"].lane_tags ==
             "module:app_env_serial; test:db_serial"

    assert by_name["test-level lane and skip"].multiplicity == 2

    # A test-level tag applies only to the next test; the neighbor stays single-lane.
    assert by_name["untagged neighbor keeps multiplicity one"].lane_tags ==
             "module:app_env_serial"

    assert by_name["untagged neighbor keeps multiplicity one"].multiplicity == 1
    assert by_name["after describe returns to module scope"].multiplicity == 1
  end

  test "skip tags are recorded verbatim and only where declared" do
    rows = fixture_rows()
    by_name = Map.new(rows, &{&1.name, &1})

    assert by_name["test-level lane and skip"].skip_tags == ~s(skip: "needs external hardware")
    assert Enum.count(rows, &(&1.skip_tags != "")) == 1
  end

  test "manifest emit and check round-trip" do
    csv = TestManifest.csv(fixture_rows())

    assert String.starts_with?(
             csv,
             ~s("owner","path","module","kind","describe","name","primary_lane",) <>
               ~s("lane_tags","skip_tags","multiplicity")
           )

    assert TestManifest.check(csv, csv) == :ok
  end

  test "check names lost rows, new rows, and pure reordering" do
    csv = TestManifest.csv(fixture_rows())
    [header | rows] = String.split(csv, "\n", trim: true)
    [first_row | remaining_rows] = rows

    # A row present in the committed manifest but missing live is a loss.
    live_without_first = Enum.join([header | remaining_rows], "\n") <> "\n"
    assert {:error, summary} = TestManifest.check(live_without_first, csv)
    assert summary =~ "only in committed manifest (lost or changed in the tree): 1"
    assert summary =~ first_row

    # A live-only row is new/uncommitted drift.
    assert {:error, summary} = TestManifest.check(csv, live_without_first)
    assert summary =~ "only in live regeneration (new or changed in the tree): 1"

    # Identical rows in a different order still fail, with a targeted note.
    reordered = Enum.join([header | Enum.reverse(rows)], "\n") <> "\n"
    assert {:error, summary} = TestManifest.check(reordered, csv)
    assert summary =~ "same rows in a different order"
  end
end
