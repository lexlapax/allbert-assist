defmodule AllbertAssist.Resources.ImageBoundsTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Resources.ImageBounds

  @profile %{
    media: %{
      "image_formats_supported" => ["png", "jpeg", "webp"],
      "max_image_bytes" => 4_096,
      "max_image_pixels" => 1_000_000
    }
  }

  test "validates image input against profile and global settings bounds" do
    assert {:ok, validation} =
             ImageBounds.validate_input(
               %{
                 mime_type: "image/png",
                 byte_size: 2_048,
                 width: 320,
                 height: 240
               },
               @profile,
               settings: %{
                 "vision" => %{
                   "media" => %{"max_bytes" => 3_000, "max_pixels" => 500_000}
                 }
               }
             )

    assert validation.format == "png"
    assert validation.byte_size == 2_048
    assert validation.pixel_count == 76_800
    assert validation.max_bytes == 3_000
    assert validation.max_pixels == 500_000
  end

  test "rejects unsupported image formats before provider calls" do
    assert {:error, {:unsupported_image_format, "gif", ["png", "jpeg", "webp"]}} =
             ImageBounds.validate_input(
               %{format: "gif", byte_size: 2_048, width: 320, height: 240},
               @profile
             )
  end

  test "rejects oversized image input before provider calls" do
    assert {:error, {:image_input_too_large, 4_097, 4_096}} =
             ImageBounds.validate_input(
               %{format: "png", byte_size: 4_097, width: 320, height: 240},
               @profile
             )
  end

  test "rejects image input without trusted dimensions" do
    assert {:error, :missing_image_dimensions} =
             ImageBounds.validate_input(%{format: "png", byte_size: 2_048}, @profile)
  end

  test "validates generated image output against image generation settings" do
    assert {:error, {:image_output_too_many_pixels, 1_200_000, 500_000}} =
             ImageBounds.validate_generated(
               %{format: "png", byte_size: 2_048, pixel_count: 1_200_000},
               @profile,
               settings: %{
                 "image" => %{
                   "generation" => %{"max_bytes" => 3_000, "max_pixels" => 500_000}
                 }
               }
             )
  end
end
