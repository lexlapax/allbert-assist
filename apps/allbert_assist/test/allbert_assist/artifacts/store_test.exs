defmodule AllbertAssist.Artifacts.StoreTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Artifacts.Store

  @moduletag :home_fs_serial

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-artifacts-store-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "hashes binaries and streams with lowercase sha256", %{root: root} do
    bytes = "artifact payload"

    assert Store.sha256(bytes) ==
             "a11a4045c89f727fadb9aeddb0f29637ce5b505846afebd82ae2c01b6733a6b5"

    assert Store.sha256_stream(["artifact", " ", "payload"]) == Store.sha256(bytes)

    assert {:ok, object} = Store.put(bytes, root: root)
    assert object.sha256 == Store.sha256(bytes)
    assert object.byte_size == byte_size(bytes)
    assert object.path == Store.object_path!(object.sha256, root: root)
    assert String.match?(object.sha256, ~r/^[0-9a-f]{64}$/)
  end

  test "stores objects under a two-level shard layout and reads by hash", %{root: root} do
    bytes = "sharded artifact"
    sha = Store.sha256(bytes)

    assert {:ok, %{sha256: ^sha, deduped?: false}} = Store.put(bytes, root: root)

    assert Store.object_path!(sha, root: root) ==
             Path.join([root, "objects", String.slice(sha, 0, 2), String.slice(sha, 2, 2), sha])

    assert {:ok, ^bytes} = Store.read(sha, root: root)
    assert Store.exists?(sha, root: root)
  end

  test "deduplicates repeated writes without changing the object", %{root: root} do
    bytes = "deduplicated artifact"

    assert {:ok, first} = Store.put(bytes, root: root)
    assert {:ok, second} = Store.put(bytes, root: root)

    assert first.sha256 == second.sha256
    assert first.path == second.path
    assert first.deduped? == false
    assert second.deduped? == true
    assert {:ok, ^bytes} = Store.read(first.sha256, root: root)
  end

  test "validates object hashes before reading paths", %{root: root} do
    assert {:error, :invalid_sha256} = Store.object_path("not-a-sha", root: root)
    assert {:error, :invalid_sha256} = Store.read("not-a-sha", root: root)
  end
end
