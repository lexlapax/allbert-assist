defmodule AllbertAssist.Artifacts.BoundsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Artifacts
  alias AllbertAssist.Artifacts.Bounds
  alias AllbertAssist.Artifacts.Store

  @moduletag :home_fs_serial

  setup do
    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-artifacts-bounds-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(root)

    on_exit(fn -> File.rm_rf!(root) end)

    {:ok, root: root}
  end

  test "allows bounded artifacts with exact and wildcard mime settings" do
    assert {:ok, bounds} =
             Bounds.validate("hello", %{mime: "text/plain"},
               max_bytes: 16,
               allowed_mime: ["text/*"]
             )

    assert bounds.byte_size == 5
    assert bounds.max_bytes == 16
    assert bounds.mime == "text/plain"

    assert {:ok, _bounds} =
             Bounds.validate("pdf", %{"mime_type" => "application/pdf"},
               allowed_mime: ["application/pdf"]
             )
  end

  test "rejects oversized and disallowed artifacts" do
    assert {:error, {:artifact_too_large, 9, 8}} =
             Bounds.validate("123456789", %{mime: "text/plain"}, max_bytes: 8)

    assert {:error, {:artifact_mime_not_allowed, "application/octet-stream", ["text/*"]}} =
             Bounds.validate("hello", %{mime: "application/octet-stream"},
               allowed_mime: ["text/*"]
             )

    assert {:error, {:artifact_type_not_allowed, "video", ["audio", "image"]}} =
             Bounds.validate("video", %{mime: "video/mp4"}, allowed_types: ["audio", "image"])
  end

  test "artifact facade enforces bounds before durable write", %{root: root} do
    bytes = "too large"
    sha = Store.sha256(bytes)

    assert {:error, {:artifact_too_large, 9, 4}} =
             Artifacts.put(bytes, %{mime: "text/plain"}, root: root, max_bytes: 4)

    refute Store.exists?(sha, root: root)
    refute File.exists?(Store.object_path!(sha, root: root))
  end
end
