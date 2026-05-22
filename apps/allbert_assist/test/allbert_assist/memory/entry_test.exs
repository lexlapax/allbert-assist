defmodule AllbertAssist.Memory.EntryTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Memory.Entry

  test "builds a normalized struct from legacy memory maps" do
    entry =
      Entry.from_map(%{
        path: "/tmp/memory/notes/example.md",
        category: :notes,
        timestamp: "2026-05-15T12:00:00Z",
        source_signal_id: "sig-1",
        actor: "alice",
        agent: "AllbertAssist.Agents.IntentAgent",
        channel: "cli",
        app_id: "stocksage",
        namespace: "stocksage",
        kind: "stocksage_lesson",
        idempotency_key: "analysis-1:outcome-1",
        source_ref: "stocksage:analysis:analysis-1",
        summary: "Remember this",
        body: "The body"
      })

    assert entry.category == :notes
    assert entry.app_id == "stocksage"
    assert entry.namespace == "stocksage"
    assert entry.kind == "stocksage_lesson"
    assert entry.idempotency_key == "analysis-1:outcome-1"
    assert entry.source_ref == "stocksage:analysis:analysis-1"
    assert entry.review_status == :unreviewed
    assert entry.reviewed_at == nil
    assert Entry.to_map(entry, include_body: false)[:body] == nil
    assert Entry.to_map(entry, include_body: false)[:app_id] == "stocksage"
  end

  test "keeps parsed review metadata from maps" do
    entry =
      Entry.from_map(%{
        path: "/tmp/memory/preferences/example.md",
        category: "preferences",
        timestamp: "2026-05-15T12:00:00Z",
        summary: "Preference",
        body: "Body",
        review_status: "flagged",
        reviewed_at: "2026-05-15T13:00:00Z",
        reviewed_by: "alice",
        correction_note: "stale"
      })

    assert entry.category == :preferences
    assert entry.review_status == :flagged
    assert entry.correction_note == "stale"
  end
end
