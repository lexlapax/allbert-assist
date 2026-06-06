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
end
