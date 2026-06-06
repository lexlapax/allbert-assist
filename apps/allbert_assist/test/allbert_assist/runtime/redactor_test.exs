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

  test "surface-specific runtime redaction uses the same strict policy" do
    payload = %{
      resource_access: %{raw_response: %{token: "secret"}},
      stocksage: %{raw_bridge_body: "secret://stocksage/token"}
    }

    assert Redactor.redact(payload, :resource_access) == Redactor.redact(payload)
    assert Redactor.redact(payload, :voice) == Redactor.redact(payload)
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

  test "runtime posture and sensitive key checks preserve legacy policy" do
    assert Redactor.posture() == LegacyRedactor.posture()
    assert Redactor.sensitive_key?(:api_key)
    assert Redactor.sensitive_key?("raw_response")
    refute Redactor.sensitive_key?("credential_status")
  end
end
