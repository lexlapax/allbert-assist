defmodule AllbertAssist.Runtime.RedactorTest do
  use ExUnit.Case, async: true

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
    assert Redactor.redact(payload, :stocksage) == Redactor.redact(payload)
    assert Redactor.redact(payload, :sandbox_trial) == Redactor.redact(payload)
  end

  test "runtime posture and sensitive key checks preserve legacy policy" do
    assert Redactor.posture() == LegacyRedactor.posture()
    assert Redactor.sensitive_key?(:api_key)
    assert Redactor.sensitive_key?("raw_response")
    refute Redactor.sensitive_key?("credential_status")
  end
end
