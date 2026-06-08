defmodule AllbertAssist.Artifacts.GCTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Artifacts
  alias AllbertAssist.Artifacts.GC
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store

  @moduletag :home_fs_serial

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-artifacts-gc-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    MetadataIndex.reset_cache!()

    on_exit(fn ->
      MetadataIndex.reset_cache!()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "sweep removes unindexed object orphans without touching retained artifacts", %{root: root} do
    assert {:ok, retained} =
             Artifacts.put("retained bytes", %{mime: "text/plain", retention: "retained"},
               root: root
             )

    assert {:ok, orphan} = Store.put("orphan bytes", root: root)

    assert {:ok, summary} = GC.sweep(root: root, delete_orphans?: true)

    assert summary.status == :completed
    assert summary.orphans == [orphan.sha256]
    assert summary.removed_count == 1
    assert [%{sha256: orphan_sha}] = summary.removed
    assert orphan_sha == orphan.sha256
    assert retained.sha256 in summary.retained

    assert Store.exists?(retained.sha256, root: root)
    refute Store.exists?(orphan.sha256, root: root)
    assert {:ok, _metadata} = MetadataIndex.lookup(retained.sha256, root: root)
  end

  test "sweep reports orphans without deleting when policy disables orphan removal", %{root: root} do
    assert {:ok, orphan} = Store.put("orphan bytes", root: root)

    assert {:ok, summary} = GC.sweep(root: root, delete_orphans?: false)

    assert summary.orphans == [orphan.sha256]
    assert summary.removed_count == 0
    assert summary.removed == []
    assert Store.exists?(orphan.sha256, root: root)
  end

  test "supervised GC worker runs an on-demand sweep", %{root: root} do
    name = :"artifact_gc_test_#{System.unique_integer([:positive])}"
    start_supervised!({GC, name: name, root: root})

    assert {:ok, orphan} = Store.put("orphan bytes", root: root)
    assert {:ok, summary} = GC.run_once(name, delete_orphans?: true)

    assert summary.orphans == [orphan.sha256]
    assert summary.removed_count == 1
    refute Store.exists?(orphan.sha256, root: root)
  end
end
