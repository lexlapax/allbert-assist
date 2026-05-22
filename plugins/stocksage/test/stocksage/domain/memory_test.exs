defmodule StockSage.Domain.MemoryTest do
  use StockSage.DataCase

  alias StockSage.Memory

  describe "memory entries" do
    test "stores StockSage-local memory without markdown promotion" do
      assert {:ok, entry} =
               Memory.create_entry(%{
                 user_id: "alice",
                 content: "Prefer earnings trend context.",
                 kind: "lesson",
                 source: "operator"
               })

      refute entry.promoted_to_allbert_memory
      assert entry.allbert_memory_path == nil
      assert {:ok, ^entry} = Memory.get_entry("alice", entry.id)
      assert {:error, :not_found} = Memory.get_entry("bob", entry.id)
    end

    test "filters by user and kind" do
      assert {:ok, lesson} =
               Memory.create_entry(%{user_id: "alice", content: "lesson", kind: "lesson"})

      assert {:ok, _note} =
               Memory.create_entry(%{user_id: "alice", content: "note", kind: "note"})

      assert [listed] = Memory.list_entries("alice", kind: "lesson")
      assert listed.id == lesson.id
      assert [] = Memory.list_entries("bob")
    end

    test "filters by analysis id" do
      assert {:ok, aapl} =
               StockSage.Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: "aapl",
                 status: "completed",
                 source: "manual"
               })

      assert {:ok, msft} =
               StockSage.Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: "msft",
                 status: "completed",
                 source: "manual"
               })

      assert {:ok, reflection} =
               Memory.create_entry(%{
                 user_id: "alice",
                 analysis_id: aapl.id,
                 content: "reflection",
                 kind: "reflection"
               })

      assert {:ok, _other} =
               Memory.create_entry(%{
                 user_id: "alice",
                 analysis_id: msft.id,
                 content: "other",
                 kind: "reflection"
               })

      assert [listed] = Memory.list_entries("alice", kind: "reflection", analysis_id: aapl.id)
      assert listed.id == reflection.id
    end

    test "upserts by legacy provenance" do
      attrs = %{
        user_id: "alice",
        content: "old",
        kind: "note",
        source: "legacy_sqlite",
        legacy_source: "stocksage.db",
        legacy_id: "mem-1"
      }

      assert {:ok, first} = Memory.upsert_entry(attrs)
      assert {:ok, second} = Memory.upsert_entry(%{attrs | content: "new"})

      assert first.id == second.id
      assert second.content == "new"
      assert [_one] = Memory.list_entries("alice")
    end
  end
end
