defmodule AllbertAssist.Resources.ImageMetadataTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Resources.ImageMetadata

  @png Base.decode64!(
         "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADElEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
       )

  test "extracts bounded PNG metadata from server-side bytes" do
    path = write_temp!("allbert-image-metadata", ".png", @png)

    assert {:ok, metadata} =
             ImageMetadata.from_path(path,
               resource_uri: "image://capture/img_123",
               filename: "sample.png",
               transient?: true
             )

    assert metadata.path == path
    assert metadata.resource_uri == "image://capture/img_123"
    assert metadata.filename == "sample.png"
    assert metadata.image_format == "png"
    assert metadata.mime_type == "image/png"
    assert metadata.width == 1
    assert metadata.height == 1
    assert metadata.pixel_count == 1
    assert metadata.byte_size == byte_size(@png)
    assert byte_size(metadata.content_sha256) == 64
    assert metadata.redaction_status == "metadata_only"
    assert metadata.transient?
  end

  test "rejects files above the read bound before parsing" do
    path = write_temp!("allbert-image-metadata-large", ".png", @png)

    assert {:error, {:image_input_too_large, size, 8}} =
             ImageMetadata.from_path(path, max_bytes: 8)

    assert size == byte_size(@png)
  end

  test "rejects truncated jpeg headers without raising" do
    path =
      write_temp!(
        "allbert-image-metadata-truncated",
        ".jpg",
        <<0xFF, 0xD8, 0xFF, 0xC0, 0x00, 0x10>>
      )

    assert {:error, :invalid_jpeg_header} = ImageMetadata.from_path(path)
  end

  defp write_temp!(prefix, extension, bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "#{prefix}-#{System.unique_integer([:positive])}#{extension}"
      )

    File.write!(path, bytes)
    on_exit(fn -> File.rm(path) end)

    path
  end
end
