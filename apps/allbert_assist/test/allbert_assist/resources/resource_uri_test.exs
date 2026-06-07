defmodule AllbertAssist.Resources.ResourceURITest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Resources.ResourceURI

  test "normalizes microphone capture resource uris" do
    assert {:ok, "mic://capture/cap_123"} = ResourceURI.mic_capture("cap_123")
    assert ResourceURI.mic_capture!("cap-123") == "mic://capture/cap-123"
    assert {:ok, "mic://capture/cap_123"} = ResourceURI.normalize(" mic://capture/cap_123 ")
  end

  test "derives microphone capture scope fields" do
    assert {:ok, fields} = ResourceURI.derived_fields("mic://capture/cap_123")

    assert fields.origin_kind == :audio_capture
    assert fields.canonical_id == "mic://capture/cap_123"
    assert fields.capture_id == "cap_123"
    refute fields.unsupported?

    assert {:ok, "mic://capture/cap_123"} =
             ResourceURI.scope_uri(
               :audio_capture,
               :audio_capture,
               "cap_123",
               "mic://capture/ignored"
             )
  end

  test "rejects malformed microphone capture uris" do
    assert {:error, {:invalid_mic_capture_uri, "mic://capture/"}} =
             ResourceURI.normalize("mic://capture/")

    assert {:error, {:invalid_mic_capture_uri, "mic://capture/cap/extra"}} =
             ResourceURI.normalize("mic://capture/cap/extra")

    assert {:error, {:invalid_mic_capture_uri, "mic://capture/cap?x=1"}} =
             ResourceURI.normalize("mic://capture/cap?x=1")

    assert {:error, {:invalid_mic_capture_id, "cap.bad"}} =
             ResourceURI.normalize("mic://capture/cap.bad")
  end

  test "normalizes image and screen capture resource uris" do
    assert {:ok, "image://capture/img_123"} = ResourceURI.image_capture("img_123")
    assert ResourceURI.image_capture!("img-123") == "image://capture/img-123"
    assert {:ok, "screen://capture/shot_123"} = ResourceURI.screen_capture("shot_123")
    assert ResourceURI.screen_capture!("shot-123") == "screen://capture/shot-123"

    assert {:ok, "image://capture/img_123"} =
             ResourceURI.normalize(" image://capture/img_123 ")

    assert {:ok, "screen://capture/shot_123"} =
             ResourceURI.normalize(" screen://capture/shot_123 ")
  end

  test "derives image input scope fields for image and screen captures" do
    assert {:ok, image_fields} = ResourceURI.derived_fields("image://capture/img_123")
    assert image_fields.origin_kind == :image_input
    assert image_fields.canonical_id == "image://capture/img_123"
    assert image_fields.capture_id == "img_123"
    assert image_fields.media_kind == :image
    refute image_fields.unsupported?

    assert {:ok, screen_fields} = ResourceURI.derived_fields("screen://capture/shot_123")
    assert screen_fields.origin_kind == :image_input
    assert screen_fields.canonical_id == "screen://capture/shot_123"
    assert screen_fields.capture_id == "shot_123"
    assert screen_fields.media_kind == :screen
    refute screen_fields.unsupported?

    assert {:ok, "image://capture/img_123"} =
             ResourceURI.scope_uri(
               :image_input,
               :image_input,
               "img_123",
               "image://capture/ignored"
             )

    assert {:ok, "screen://capture/shot_123"} =
             ResourceURI.scope_uri(
               :image_input,
               :image_input,
               "screen://capture/shot_123",
               "image://capture/ignored"
             )
  end

  test "rejects malformed image and screen capture uris" do
    assert {:error, {:invalid_image_capture_uri, "image://capture/"}} =
             ResourceURI.normalize("image://capture/")

    assert {:error, {:invalid_image_capture_uri, "image://capture/img/extra"}} =
             ResourceURI.normalize("image://capture/img/extra")

    assert {:error, {:invalid_image_capture_uri, "image://capture/img?x=1"}} =
             ResourceURI.normalize("image://capture/img?x=1")

    assert {:error, {:invalid_image_capture_id, "img.bad"}} =
             ResourceURI.normalize("image://capture/img.bad")

    assert {:error, {:invalid_screen_capture_uri, "screen://capture/shot/extra"}} =
             ResourceURI.normalize("screen://capture/shot/extra")

    assert {:error, {:invalid_screen_capture_id, "shot.bad"}} =
             ResourceURI.normalize("screen://capture/shot.bad")
  end
end
