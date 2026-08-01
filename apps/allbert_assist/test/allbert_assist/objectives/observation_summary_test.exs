defmodule AllbertAssist.Objectives.ObservationSummaryTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Objectives.ObservationSummary

  test "redacts at the signal boundary before returning durable text" do
    normalized =
      ObservationSummary.normalize("token=Bearer DUMMYSecretShapeForAudit59 completed")

    assert normalized =~ "[REDACTED]"
    refute normalized =~ "DUMMYSecretShapeForAudit59"
  end

  test "truncates an overlong UTF-8 summary to 2,000 characters with an ellipsis" do
    normalized = ObservationSummary.normalize(String.duplicate("界", 2_001))

    assert normalized == String.duplicate("界", 1_999) <> "…"
    assert String.length(normalized) == 2_000
    assert String.valid?(normalized)
  end

  test "preserves an exact-bound Unicode summary" do
    summary = String.duplicate("界", 2_000)

    assert ObservationSummary.normalize(summary) == summary
  end

  test "converts supported non-binary observations to text" do
    assert ObservationSummary.normalize(:completed) == "completed"
    assert ObservationSummary.normalize(42) == "42"
  end
end
