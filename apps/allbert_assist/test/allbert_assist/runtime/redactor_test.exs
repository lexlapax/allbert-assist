defmodule AllbertAssist.Runtime.RedactorTest do
  use ExUnit.Case, async: true
  @moduletag :external_runtime_serial

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.Redactor, as: LegacyRedactor

  defmodule FixtureStruct do
    defstruct [:api_key, :safe]
  end

  test "runtime facade preserves existing secret and key redaction behavior" do
    value = %{
      api_key: "sk-test",
      provider_ref: "secret://providers/openai/api_key",
      authorization_header: "Bearer token",
      nested: [
        %{password: "pw"},
        %{safe: "visible"},
        %FixtureStruct{api_key: "struct-secret", safe: "struct-visible"}
      ]
    }

    assert Redactor.redact(value) == LegacyRedactor.redact(value)
    redacted = Redactor.redact(value)

    assert redacted.api_key == "[REDACTED]"
    assert redacted.provider_ref == "[SECRET_REF]"
    assert redacted.authorization_header == "[REDACTED]"
    assert [%{password: "[REDACTED]"}, %{safe: "visible"}, struct_map] = redacted.nested
    assert struct_map.api_key == "[REDACTED]"
    assert struct_map.safe == "struct-visible"
    assert struct_map.__struct__ == "AllbertAssist.Runtime.RedactorTest.FixtureStruct"
  end

  test "redact is total on improper lists (must never raise and crash a caller)" do
    # An improper list (binary tail) crashed Enum.map and took down the Slack
    # adapter on a real inbound message. Redaction is a safety facade; it must
    # degrade gracefully instead of raising.
    improper = [%{api_key: "sk-secret"}, "visible" | "messages"]

    # improper lists are folded into proper (JSON-safe) lists, never raising
    assert [%{api_key: "[REDACTED]"}, "visible", "messages"] = Redactor.redact(improper)
    # nested under a map key, mirroring the real crash shape
    assert %{"data" => [%{api_key: "[REDACTED]"}, "tail"]} =
             Redactor.redact(%{"data" => [%{api_key: "sk-secret"} | "tail"]})
  end

  test "surface-specific runtime redaction uses the same strict policy" do
    payload = %{
      resource_access: %{raw_response: %{token: "secret"}},
      stocksage: %{raw_bridge_body: "secret://stocksage/token"}
    }

    assert Redactor.redact(payload, :resource_access) == Redactor.redact(payload)
    assert Redactor.redact(payload, :voice) == Redactor.redact(payload)
    assert Redactor.redact(payload, :vision) == Redactor.redact(payload)
    assert Redactor.redact(payload, :image) == Redactor.redact(payload)
    assert Redactor.redact(payload, :artifacts) == Redactor.redact(payload)
    assert Redactor.redact(payload, :stocksage) == Redactor.redact(payload)
    assert Redactor.redact(payload, :sandbox_trial) == Redactor.redact(payload)
  end

  test "audio metadata redaction drops raw payloads and local paths" do
    redacted =
      Redactor.redact_audio_metadata(%{
        resource_uri: "file:///Users/spuri/private/hello.wav",
        duration_ms: 1_200,
        byte_size: 42,
        mime_type: "audio/wav",
        provider_profile: "voice_stt_fake",
        transcript_sha256: "abc123",
        usage: %{input_audio_seconds: 1.2, raw_response: %{token: "secret"}},
        raw_audio: <<1, 2, 3>>,
        source_path: "/Users/spuri/private/hello.wav",
        transcript: "hello world"
      })

    assert redacted.resource_uri == "file://[REDACTED_AUDIO_PATH]"
    assert redacted.duration_ms == 1_200
    assert redacted.byte_size == 42
    assert redacted.mime_type == "audio/wav"
    assert redacted.provider_profile == "voice_stt_fake"
    assert redacted.transcript_sha256 == "abc123"
    assert redacted.usage.raw_response == "[REDACTED]"
    refute Map.has_key?(redacted, :raw_audio)
    refute Map.has_key?(redacted, :source_path)
    refute Map.has_key?(redacted, :transcript)
    refute inspect(redacted) =~ "/Users/spuri"
    refute inspect(redacted) =~ "hello world"
  end

  test "audio metadata keeps valid microphone capture identity only" do
    assert %{resource_uri: "mic://capture/cap_123"} =
             Redactor.redact_audio_metadata(%{resource_uri: "mic://capture/cap_123"})

    assert %{resource_uri: "[REDACTED_AUDIO_URI]"} =
             Redactor.redact_audio_metadata(%{resource_uri: "mic://capture/cap.bad"})
  end

  test "image metadata redaction drops raw payloads, prompts, and local paths" do
    redacted =
      Redactor.redact_image_metadata(%{
        resource_uri: "file:///Users/spuri/private/frame.png",
        width: 640,
        height: 480,
        byte_size: 42,
        mime_type: "image/png",
        provider_profile: "vision_fake",
        content_sha256: "abc123",
        usage: %{input_image_count: 1, raw_response: %{token: "secret"}},
        raw_image: <<1, 2, 3>>,
        source_path: "/Users/spuri/private/frame.png",
        prompt: "read this secret whiteboard",
        provider_payload: %{api_key: "secret"}
      })

    assert redacted.resource_uri == "file://[REDACTED_IMAGE_PATH]"
    assert redacted.width == 640
    assert redacted.height == 480
    assert redacted.byte_size == 42
    assert redacted.mime_type == "image/png"
    assert redacted.provider_profile == "vision_fake"
    assert redacted.content_sha256 == "abc123"
    assert redacted.usage.raw_response == "[REDACTED]"
    refute Map.has_key?(redacted, :raw_image)
    refute Map.has_key?(redacted, :source_path)
    refute Map.has_key?(redacted, :prompt)
    refute Map.has_key?(redacted, :provider_payload)
    refute inspect(redacted) =~ "/Users/spuri"
    refute inspect(redacted) =~ "secret whiteboard"
  end

  test "image metadata keeps valid image and screen capture identity only" do
    assert %{resource_uri: "image://capture/img_123"} =
             Redactor.redact_image_metadata(%{resource_uri: "image://capture/img_123"})

    assert %{resource_uri: "screen://capture/shot_123"} =
             Redactor.redact_image_metadata(%{resource_uri: "screen://capture/shot_123"})

    assert %{resource_uri: "[REDACTED_IMAGE_URI]"} =
             Redactor.redact_image_metadata(%{resource_uri: "image://capture/img.bad"})

    assert %{resource_uri: "[REDACTED_IMAGE_URI]"} =
             Redactor.redact_image_metadata(%{resource_uri: "https://example.com/frame.png"})
  end

  test "artifact metadata redaction drops bytes and local paths" do
    sha = String.duplicate("a", 64)

    redacted =
      Redactor.redact_artifact_metadata(%{
        resource_uri: "artifact://sha256/#{sha}",
        sha256: sha,
        content_sha256: sha,
        mime: "text/plain",
        byte_size: 12,
        origin: "assistant",
        source_resource_uri: "file:///Users/spuri/private/report.txt",
        provenance: %{thread_id: "thread_1", token: "secret"},
        raw_bytes: "secret bytes",
        local_path: "/Users/spuri/private/report.txt"
      })

    assert redacted.resource_uri == "artifact://sha256/#{sha}"
    assert redacted.sha256 == sha
    assert redacted.content_sha256 == sha
    assert redacted.mime == "text/plain"
    assert redacted.byte_size == 12
    assert redacted.source_resource_uri == "[REDACTED_ARTIFACT_URI]"
    assert redacted.provenance.token == "[REDACTED]"
    refute Map.has_key?(redacted, :raw_bytes)
    refute Map.has_key?(redacted, :local_path)
    refute inspect(redacted) =~ "/Users/spuri"
    refute inspect(redacted) =~ "secret bytes"
  end

  test "artifact metadata keeps valid artifact identity only" do
    sha = String.duplicate("b", 64)
    uri = "artifact://sha256/#{sha}"

    assert %{resource_uri: ^uri} =
             Redactor.redact_artifact_metadata(%{resource_uri: uri})

    assert %{resource_uri: "[REDACTED_ARTIFACT_URI]"} =
             Redactor.redact_artifact_metadata(%{resource_uri: "artifact://sha256/not-a-sha"})
  end

  test "runtime posture and sensitive key checks preserve legacy policy" do
    assert Redactor.posture() == LegacyRedactor.posture()
    assert Redactor.sensitive_key?(:api_key)
    assert Redactor.sensitive_key?("raw_response")
    refute Redactor.sensitive_key?("credential_status")
  end
end
