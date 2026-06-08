defmodule AllbertAssist.Artifacts.MetadataIndexTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store

  @moduletag :home_fs_serial

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-artifacts-index-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)
    MetadataIndex.reset_cache!()

    on_exit(fn ->
      MetadataIndex.reset_cache!()
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "writes markdown sidecars with only allow-listed metadata", %{root: root} do
    sha = Store.sha256("indexed artifact")

    metadata = %{
      sha256: sha,
      mime: "text/plain",
      byte_size: 16,
      origin: "assistant",
      source_resource_uri: "allbert://threads/thread_1/messages/msg_1",
      created_at: "2026-06-08T12:00:00Z",
      retention: "normal",
      redaction_status: "none",
      lifecycle: "active",
      provenance: %{"thread_id" => "thread_1"},
      raw_bytes: "must not persist",
      local_path: "/tmp/not-authority"
    }

    assert {:ok, written} = MetadataIndex.write(metadata, root: root)
    assert Map.keys(written) |> Enum.sort() == MetadataIndex.allowed_keys() |> Enum.sort()

    sidecar_path = MetadataIndex.sidecar_path!(sha, root: root)
    assert File.exists?(sidecar_path)

    assert {:ok, markdown} = File.read(sidecar_path)
    assert markdown =~ "# Artifact #{sha}"
    assert markdown =~ "```json"
    refute markdown =~ "raw_bytes"
    refute markdown =~ "local_path"

    assert {:ok, read} = MetadataIndex.read(sha, root: root)
    assert read == written
  end

  test "maintains a sha256 lookup cache backed by markdown sidecars", %{root: root} do
    sha = Store.sha256("cacheable artifact")
    metadata = %{sha256: sha, mime: "text/plain", byte_size: 18, lifecycle: "active"}

    assert {:ok, written} = MetadataIndex.write(metadata, root: root)
    assert {:ok, ^written} = MetadataIndex.lookup(sha, root: root)

    MetadataIndex.reset_cache!()

    assert {:ok, ^written} = MetadataIndex.lookup(sha, root: root)
  end

  test "preserves zero-byte metadata values", %{root: root} do
    sha = Store.sha256("")

    assert {:ok, written} =
             MetadataIndex.write(%{sha256: sha, mime: "text/plain", byte_size: 0}, root: root)

    assert written.byte_size == 0
    assert {:ok, ^written} = MetadataIndex.read(sha, root: root)
  end

  test "lists metadata sidecars from the index", %{root: root} do
    first = %{sha256: Store.sha256("first"), mime: "text/plain", byte_size: 5}
    second = %{sha256: Store.sha256("second"), mime: "text/plain", byte_size: 6}

    assert {:ok, _} = MetadataIndex.write(first, root: root)
    assert {:ok, _} = MetadataIndex.write(second, root: root)

    assert {:ok, listed} = MetadataIndex.list(root: root)

    assert Enum.map(listed, & &1.sha256) |> Enum.sort() ==
             [first.sha256, second.sha256] |> Enum.sort()
  end

  test "rejects invalid or missing sha256 metadata", %{root: root} do
    assert {:error, :missing_sha256} = MetadataIndex.write(%{mime: "text/plain"}, root: root)
    assert {:error, :invalid_sha256} = MetadataIndex.write(%{sha256: "not-a-sha"}, root: root)
    assert {:error, :invalid_sha256} = MetadataIndex.read("not-a-sha", root: root)
  end
end
