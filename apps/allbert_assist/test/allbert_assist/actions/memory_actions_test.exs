defmodule AllbertAssist.Actions.MemoryActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Memory.CompileMemoryIndex
  alias AllbertAssist.Actions.Memory.DeleteMemoryEntry
  alias AllbertAssist.Actions.Memory.ListMemoryEntries
  alias AllbertAssist.Actions.Memory.PruneMemoryEntries
  alias AllbertAssist.Actions.Memory.ReadMemoryEntry
  alias AllbertAssist.Actions.Memory.ReviewMemoryEntry
  alias AllbertAssist.Actions.Memory.SearchMemory
  alias AllbertAssist.Actions.Memory.SummarizeMemoryCategory
  alias AllbertAssist.Actions.Memory.UpdateMemoryEntry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_confirmations = Application.get_env(:allbert_assist, Confirmations)

    home =
      Path.join(System.tmp_dir!(), "allbert-memory-actions-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(home, "confirmations"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
      restore_env(Confirmations, original_confirmations)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "list_memory_entries returns bounded entries for one user" do
    assert {:ok, _alice} = append("alice", "Alice prefers compact reports.")
    assert {:ok, _bob} = append("bob", "Bob prefers long reports.")

    assert {:ok, response} =
             ListMemoryEntries.run(%{user_id: "alice", limit: 10}, %{user_id: "alice"})

    assert response.status == :completed
    assert [%{actor: "alice", review_status: :unreviewed} = entry] = response.entries
    refute Map.has_key?(entry, :body)
  end

  test "read_memory_entry returns full entry and isolates users" do
    assert {:ok, entry} = append("alice", "Alice wants short updates.")

    assert {:ok, response} =
             ReadMemoryEntry.run(%{path: entry.path, user_id: "alice"}, %{user_id: "alice"})

    assert response.status == :completed
    assert response.entry.body =~ "short updates"

    assert {:ok, not_found} =
             ReadMemoryEntry.run(%{path: entry.path, user_id: "bob"}, %{user_id: "bob"})

    assert not_found.status == :not_found
  end

  test "read_memory_entry rejects paths outside the memory root" do
    assert {:ok, response} =
             ReadMemoryEntry.run(%{path: "/tmp/not-allbert-memory.md", user_id: "alice"}, %{
               user_id: "alice"
             })

    assert response.status == :error
    assert response.error == :path_outside_memory_root
  end

  test "review_memory_entry writes review state and update_memory_entry preserves it" do
    assert {:ok, entry} = append("alice", "Alice prefers short updates.")

    assert {:ok, reviewed} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "flagged", note: "stale", user_id: "alice"},
               %{user_id: "alice"}
             )

    assert reviewed.status == :completed
    assert reviewed.entry.review_status == :flagged
    assert reviewed.entry.correction_note == "stale"

    assert {:ok, updated} =
             UpdateMemoryEntry.run(
               %{
                 path: entry.path,
                 summary: "Concise update preference",
                 body: "Alice prefers concise implementation updates.",
                 user_id: "alice"
               },
               %{user_id: "alice"}
             )

    assert updated.status == :completed
    assert updated.entry.summary == "Concise update preference"
    assert updated.entry.body =~ "concise implementation"
    assert updated.entry.review_status == :flagged
  end

  test "delete_memory_entry creates confirmation and approval archives the file" do
    assert {:ok, entry} = append("alice", "Delete me after confirmation.")

    assert {:ok, response} =
             DeleteMemoryEntry.run(%{path: entry.path, user_id: "alice"}, %{
               user_id: "alice",
               actor: "alice",
               channel: :test
             })

    assert response.status == :needs_confirmation
    assert File.exists?(entry.path)

    assert {:ok, approved} =
             ApproveConfirmation.run(%{id: response.confirmation_id, reason: "test"}, %{
               user_id: "alice",
               actor: "alice",
               channel: :test
             })

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    refute File.exists?(entry.path)
    assert [%{confirmation_metadata: %{target_resumed?: true}}] = approved.actions
  end

  test "prune_memory_entries dry-run and approval archive prune-nominated entries" do
    assert {:ok, entry} = append("alice", "Prune me after review.")

    assert {:ok, _reviewed} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "prune_nominated", user_id: "alice"},
               %{user_id: "alice"}
             )

    assert {:ok, dry_run} = PruneMemoryEntries.run(%{user_id: "alice"}, %{user_id: "alice"})
    assert dry_run.status == :completed
    assert [%{path: path, reason: :prune_nominated}] = dry_run.candidates
    assert path == entry.path

    assert {:ok, pending} =
             PruneMemoryEntries.run(%{user_id: "alice", write: true}, %{
               user_id: "alice",
               actor: "alice",
               channel: :test
             })

    assert pending.status == :needs_confirmation
    assert File.exists?(entry.path)

    assert {:ok, approved} =
             ApproveConfirmation.run(%{id: pending.confirmation_id, reason: "test"}, %{
               user_id: "alice",
               actor: "alice",
               channel: :test
             })

    assert approved.status == :completed
    refute File.exists?(entry.path)
  end

  test "prune_memory_entries can require confirmation independently from delete" do
    assert {:ok, _setting} =
             Settings.put("memory.prune_requires_confirmation", false, %{audit?: false})

    assert {:ok, entry} = append("alice", "Prune immediately after review.")

    assert {:ok, _reviewed} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "prune_nominated", user_id: "alice"},
               %{user_id: "alice"}
             )

    assert {:ok, response} =
             PruneMemoryEntries.run(%{user_id: "alice", write: true}, %{user_id: "alice"})

    assert response.status == :completed
    assert response.archived != []
    refute File.exists?(entry.path)

    assert {:ok, delete_setting} = Settings.get("memory.delete_requires_confirmation")
    assert delete_setting == true
  end

  test "compile_memory_index, search_memory, and summarize_memory_category use derived artifacts" do
    assert {:ok, entry} = append("alice", "Alice prefers compact release notes.")

    assert {:ok, compiled} =
             CompileMemoryIndex.run(%{user_id: "alice"}, %{user_id: "alice"})

    assert compiled.status == :completed
    assert compiled.result.entry_count == 1
    assert File.exists?(compiled.result.path)

    assert {:ok, search} =
             SearchMemory.run(%{query: "compact release", user_id: "alice"}, %{user_id: "alice"})

    assert search.status == :completed
    assert [%{path: path, match_reasons: reasons}] = search.entries
    assert path == entry.path
    assert "keyword:compact" in reasons

    assert {:ok, summary} =
             SummarizeMemoryCategory.run(%{category: "notes", user_id: "alice"}, %{
               user_id: "alice"
             })

    assert summary.status == :completed
    assert File.read!(summary.result.path) =~ "# DERIVED - DO NOT EDIT"
  end

  defp append(actor, body) do
    Memory.append(%{
      category: :notes,
      body: body,
      actor: actor,
      agent: "test",
      channel: :test,
      source_signal_id: "sig"
    })
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
