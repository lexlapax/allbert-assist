defmodule AllbertAssist.Memory.SpanProvenanceTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Conversations.SourceEnvelope
  alias AllbertAssist.Memory.SpanProvenance

  test "all five transforms mechanically bind exact operator-authored UTF-8 byte spans" do
    source = source("My PROFILE starts 2026-08-01; value is  tea  ☕")

    fields = [
      build!("subject", source, "My", "operator_pronoun_v1"),
      build!("predicate", source, "PROFILE", "ascii_lower_v1"),
      build!("valid_from", source, "2026-08-01", "explicit_iso8601_date_v1"),
      build!("value", source, "  tea  ", "trim_ascii_whitespace_v1"),
      build!("marker", source, "☕", "identity_v1")
    ]

    claim = %{
      subject: "operator:alice",
      predicate: "profile",
      valid_from: "2026-08-01",
      value: "tea",
      marker: "☕",
      valid_to: nil
    }

    assert {:ok, verified} = SpanProvenance.verify(claim, %{fields: fields}, [source])
    assert verified["schema_version"] == 1

    assert Enum.map(verified["fields"], & &1["field"]) ==
             ~w[subject predicate valid_from value marker]
  end

  test "assistant evidence, uncovered fields, digest drift, and unlisted transforms fail closed" do
    source = source("I prefer tea")
    subject = build!("subject", source, "I", "operator_pronoun_v1")
    predicate = build!("predicate", source, "prefer", "identity_v1")
    value = build!("value", source, "tea", "identity_v1")
    claim = %{subject: "operator:alice", predicate: "prefer", value: "tea"}

    assistant = %{source | author: :assistant, role: "assistant"}

    assert {:error, :operator_source_required} =
             SpanProvenance.verify(claim, %{fields: [subject, predicate, value]}, [assistant])

    assert {:error, :uncovered_claim_field} =
             SpanProvenance.verify(claim, %{fields: [subject, value]}, [source])

    changed = put_in(value["raw_span_digest"], digest("changed"))

    assert {:error, :raw_span_digest_mismatch} =
             SpanProvenance.verify(claim, %{fields: [subject, predicate, changed]}, [source])

    unsupported = put_in(value["transform"], "model_rewrite_v1")

    assert {:error, :unsupported_span_transform} =
             SpanProvenance.verify(claim, %{fields: [subject, predicate, unsupported]}, [source])
  end

  test "byte offsets cannot split a multi-byte UTF-8 codepoint" do
    source = source("☕ tea")

    assert {:error, :invalid_utf8_span_boundary} =
             SpanProvenance.build("value", source, 1, 3, "identity_v1")
  end

  test "raw case and inferred dates cannot masquerade as deterministic normalization" do
    source = source("Tomorrow MY")

    assert {:error, :date_not_explicit} =
             build("valid_from", source, "Tomorrow", "explicit_iso8601_date_v1")

    assert {:error, :invalid_operator_pronoun} =
             build("subject", source, "Tomorrow", "operator_pronoun_v1")

    assert {:ok, field} = build("predicate", source, "MY", "ascii_lower_v1")
    assert field["normalized_value"] == "my"
  end

  defp build!(field, source, raw, transform) do
    assert {:ok, result} = build(field, source, raw, transform)
    result
  end

  defp build(field, source, raw, transform) do
    {start, length} = :binary.match(source.content, raw)
    SpanProvenance.build(field, source, start, start + length, transform)
  end

  defp source(content) do
    %SourceEnvelope{
      source_type: :conversation,
      source_id: Ecto.UUID.generate(),
      thread_id: Ecto.UUID.generate(),
      operator_id: "alice",
      user_id: "alice",
      principal_digest: digest("alice"),
      role: "user",
      author: :operator,
      trust: :private_operator,
      origin_scope: :local_operator,
      origin_overlays: [],
      surface: "tui",
      thread_kind: "general",
      content: content,
      content_digest: digest(content),
      inserted_at: ~U[2026-07-30 00:00:00Z],
      source_version: 1,
      origin: nil,
      trace_refs: []
    }
  end

  defp digest(value) do
    "sha256:" <> (:crypto.hash(:sha256, value) |> Base.encode16(case: :lower))
  end
end
