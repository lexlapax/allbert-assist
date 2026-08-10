defmodule AllbertAssist.Actions.MemoryActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Memory.CompileMemoryIndex
  alias AllbertAssist.Actions.Memory.DeleteMemoryEntry
  alias AllbertAssist.Actions.Memory.ListMemoryEntries
  alias AllbertAssist.Actions.Memory.PruneMemoryEntries
  alias AllbertAssist.Actions.Memory.ReadMemoryEntry
  alias AllbertAssist.Actions.Memory.RestoreMemoryClaim
  alias AllbertAssist.Actions.Memory.ReviewMemoryEntry
  alias AllbertAssist.Actions.Memory.SearchMemory
  alias AllbertAssist.Actions.Memory.SummarizeMemoryCategory
  alias AllbertAssist.Actions.Memory.SyncAppLesson
  alias AllbertAssist.Actions.Memory.UpdateMemoryEntry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Claims
  alias AllbertAssist.Memory.Projection
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.TestSupport.ReadyEffectContext

  setup do
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)
    original_confirmations = Application.get_env(:allbert_assist, Confirmations)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-memory-actions-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    File.rm_rf!(home)
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
             ListMemoryEntries.run(
               %{user_id: "alice", limit: 10},
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert response.status == :completed
    assert [%{actor: "alice", review_status: :unreviewed} = entry] = response.entries
    refute Map.has_key?(entry, :body)
  end

  test "read_memory_entry returns full entry and isolates users" do
    assert {:ok, entry} = append("alice", "Alice wants short updates.")

    assert {:ok, response} =
             ReadMemoryEntry.run(
               %{path: entry.path, user_id: "alice"},
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert response.status == :completed
    assert response.entry.body =~ "short updates"

    assert {:ok, not_found} =
             ReadMemoryEntry.run(
               %{path: entry.path, user_id: "bob"},
               ReadyEffectContext.attach(%{user_id: "bob"})
             )

    assert not_found.status == :not_found
  end

  test "read_memory_entry rejects paths outside the memory root" do
    assert {:ok, response} =
             ReadMemoryEntry.run(
               %{path: "/tmp/not-allbert-memory.md", user_id: "alice"},
               ReadyEffectContext.attach(%{
                 user_id: "alice"
               })
             )

    assert response.status == :error
    assert response.error == :path_outside_memory_root
  end

  test "review_memory_entry writes review state and update_memory_entry preserves it" do
    assert {:ok, entry} = append("alice", "Alice prefers short updates.")

    assert {:ok, reviewed} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "flagged", note: "stale", user_id: "alice"},
               ReadyEffectContext.attach(%{user_id: "alice"})
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
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert updated.status == :completed
    assert updated.entry.summary == "Concise update preference"
    assert updated.entry.body =~ "concise implementation"
    assert updated.entry.review_status == :flagged
  end

  test "delete_memory_entry creates confirmation and approval archives reversibly" do
    assert {:ok, entry} = append("alice", "Delete me after confirmation.")

    assert {:ok, response} =
             DeleteMemoryEntry.run(
               %{path: entry.path, user_id: "alice"},
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               })
             )

    assert response.status == :needs_confirmation
    assert File.exists?(entry.path)

    assert {:ok, approved} =
             ApproveConfirmation.run(
               %{id: response.confirmation_id, reason: "test"},
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               })
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert File.exists?(entry.path)
    assert {:ok, archived} = Claims.read_path(entry.path)
    assert List.last(archived.effective_records)["state"] == "archived"
    assert [%{confirmation_metadata: %{target_resumed?: true}}] = approved.actions

    assert {:ok, restored} =
             RestoreMemoryClaim.run(
               %{claim_id: archived.claim_id, user_id: "alice"},
               ReadyEffectContext.attach(%{
                 user_id: "alice"
               })
             )

    assert restored.status == :completed
    assert {:ok, restored_stream} = Claims.read(archived.claim_id)
    assert List.last(restored_stream.effective_records)["state"] == "kept"
  end

  test "delete_memory_entry approval rejects a claim changed after preview" do
    assert {:ok, entry} = append("alice", "Archive only this exact revision.")

    assert {:ok, pending} =
             DeleteMemoryEntry.run(
               %{path: entry.path, user_id: "alice"},
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               })
             )

    assert pending.status == :needs_confirmation

    assert {:ok, updated} =
             UpdateMemoryEntry.run(
               %{
                 path: entry.path,
                 summary: "Changed after preview",
                 body: "This is no longer the exact approved revision.",
                 user_id: "alice"
               },
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert updated.status == :completed

    assert {:ok, denied} =
             ApproveConfirmation.run(
               %{id: pending.confirmation_id, reason: "stale preview"},
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               })
             )

    assert denied.status == :completed
    assert denied.confirmation["status"] == "denied"
    assert {:ok, stream} = Claims.read_path(entry.path)
    assert stream.status == :grandfathered
  end

  test "prune_memory_entries dry-run and approval archive prune-nominated entries" do
    assert {:ok, entry} = append("alice", "Prune me after review.")

    assert {:ok, _reviewed} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "prune_nominated", user_id: "alice"},
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert {:ok, dry_run} =
             PruneMemoryEntries.run(
               %{user_id: "alice"},
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert dry_run.status == :completed
    assert [%{path: path, reason: :prune_nominated}] = dry_run.candidates
    assert path == entry.path

    assert {:ok, pending} =
             PruneMemoryEntries.run(
               %{user_id: "alice", write: true},
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               })
             )

    assert pending.status == :needs_confirmation
    assert File.exists?(entry.path)

    assert {:ok, approved} =
             ApproveConfirmation.run(
               %{id: pending.confirmation_id, reason: "test"},
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               })
             )

    assert approved.status == :completed
    assert File.exists?(entry.path)
    assert {:ok, archived} = Claims.read_path(entry.path)
    assert List.last(archived.effective_records)["action"] == "archive_nominated"
    assert List.last(archived.effective_records)["state"] == "archived"
  end

  test "prune_memory_entries can require confirmation independently from delete" do
    assert {:ok, _setting} =
             Settings.put(
               "memory.prune_requires_confirmation",
               false,
               AllbertAssist.TestSupport.ReadyEffectContext.attach(%{audit?: false})
             )

    assert {:ok, entry} = append("alice", "Prune immediately after review.")

    assert {:ok, _reviewed} =
             ReviewMemoryEntry.run(
               %{path: entry.path, status: "prune_nominated", user_id: "alice"},
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert {:ok, response} =
             PruneMemoryEntries.run(
               %{user_id: "alice", write: true},
               ReadyEffectContext.attach(%{user_id: "alice"})
             )

    assert response.status == :completed
    assert response.archived != []
    assert File.exists?(entry.path)
    assert {:ok, archived} = Claims.read_path(entry.path)
    assert List.last(archived.effective_records)["state"] == "archived"

    assert {:ok, delete_setting} = Settings.get("memory.delete_requires_confirmation")
    assert delete_setting == true
  end

  test "sync_app_lesson requires confirmation before writing namespaced app memory" do
    params = app_lesson_params()

    assert {:ok, pending} = Runner.run("sync_app_lesson", params, app_lesson_context())
    assert pending.status == :needs_confirmation
    assert pending.confirmation_id
    assert pending.message =~ "No Allbert markdown memory was written"

    assert {:ok, []} =
             Memory.list_entries(user_id: "alice", app_id: :stocksage, namespace: :stocksage)

    assert {:ok, approved} =
             ApproveConfirmation.run(
               %{id: pending.confirmation_id, reason: "operator reviewed"},
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               })
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"

    assert {:ok, [entry]} =
             Memory.list_entries(
               user_id: "alice",
               app_id: :stocksage,
               namespace: :stocksage,
               kind: :stocksage_lesson
             )

    assert entry.body =~ "Boundary: StockSage reflection reviewed by operator."
    assert entry.idempotency_key == "stocksage:analysis-aapl:30d"
    assert entry.source_ref == "stocksage:analysis:analysis-aapl"

    assert {:ok, updated} =
             SyncAppLesson.run(
               %{params | lesson_text: "Updated lesson after review."},
               Map.put(app_lesson_context(), :confirmation, %{approved?: true})
             )

    assert updated.status == :completed

    assert {:ok, [updated_entry]} =
             Memory.list_entries(user_id: "alice", app_id: "stocksage", namespace: "stocksage")

    assert updated_entry.path == entry.path
    assert updated_entry.body =~ "Updated lesson after review."
  end

  test "sync_app_lesson rejects undeclared app namespaces even after approval" do
    assert {:ok, response} =
             SyncAppLesson.run(
               %{app_lesson_params() | namespace: "unclaimed"},
               Map.put(app_lesson_context(), :confirmation, %{approved?: true})
             )

    assert response.status == :error
    assert response.error == {:unknown_memory_namespace, :unclaimed}
  end

  test "sync_app_lesson caps and redacts oversized lesson text before writing" do
    long_lesson =
      String.duplicate("A", 4_500) <>
        " TAIL_SHOULD_NOT_BE_WRITTEN secret://stocksage-token"

    assert {:ok, response} =
             SyncAppLesson.run(
               %{app_lesson_params() | lesson_text: long_lesson},
               Map.put(app_lesson_context(), :confirmation, %{approved?: true})
             )

    assert response.status == :completed

    assert {:ok, [entry]} =
             Memory.list_entries(
               user_id: "alice",
               app_id: :stocksage,
               namespace: :stocksage,
               kind: :stocksage_lesson
             )

    assert entry.body =~ "[Lesson text truncated to 4000 characters before memory sync.]"
    refute entry.body =~ "TAIL_SHOULD_NOT_BE_WRITTEN"
    refute entry.body =~ "secret://stocksage-token"
    assert String.length(entry.body) < 4_600
  end

  test "compile_memory_index and search_memory route through the Memory projection" do
    assert {:ok, entry} = append("alice", "Alice prefers compact release notes.")

    assert {:ok, _kept} =
             Memory.review_entry(
               entry.path,
               %{status: :kept, reviewed_by: "alice", reviewed_at: "2026-07-29T12:00:00Z"},
               user_id: "alice"
             )

    assert {:ok, projection} =
             Projection.start_link(root: Paths.memory_projection_root(), name: nil)

    context = %{user_id: "alice", memory_projection: projection}

    assert {:ok, compiled} =
             CompileMemoryIndex.run(%{user_id: "alice"}, context)

    assert compiled.status == :completed
    assert compiled.result.entry_count == 1
    assert compiled.result.categories == ["notes"]
    refute compiled.result.partial?
    assert File.exists?(compiled.result.path)

    assert {:ok, search} =
             SearchMemory.run(%{query: "compact release", user_id: "alice"}, context)

    assert search.status == :completed
    assert [%{path: path, match_reasons: reasons}] = search.entries
    assert path == entry.path
    assert "keyword:compact" in reasons
    assert [%{source: :projection}] = search.actions

    assert {:ok, summary} =
             SummarizeMemoryCategory.run(
               %{category: "notes", user_id: "alice"},
               ReadyEffectContext.attach(%{
                 user_id: "alice"
               })
             )

    assert summary.status == :completed
    assert File.read!(summary.result.path) =~ "# DERIVED - DO NOT EDIT"
    GenServer.stop(projection)
  end

  test "compile_memory_index reports a capped rebuild without promoting partial data" do
    for body <- ["first capped claim", "second capped claim"] do
      assert {:ok, entry} = append("alice", body)

      assert {:ok, _kept} =
               Memory.review_entry(
                 entry.path,
                 %{status: :kept, reviewed_by: "alice", reviewed_at: "2026-07-29T12:00:00Z"},
                 user_id: "alice"
               )
    end

    assert {:ok, projection} =
             Projection.start_link(root: Paths.memory_projection_root(), name: nil)

    assert {:ok, response} =
             CompileMemoryIndex.run(
               %{user_id: "alice", max_entries: 1},
               %{user_id: "alice", memory_projection: projection}
             )

    assert response.status == :degraded
    assert response.result.entry_count == 0
    assert response.result.max_entries == 1
    assert response.result.discovered_entries == 2
    assert response.result.partial?
    refute File.exists?(response.result.path)
    GenServer.stop(projection)
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

  defp app_lesson_params do
    %{
      user_id: "alice",
      app_id: "stocksage",
      namespace: "stocksage",
      analysis_id: "analysis-aapl",
      outcome_id: "outcome-aapl",
      objective_id: "objective-aapl",
      ticker: "AAPL",
      rating: "buy",
      realized_return: "4.2",
      holding_period_days: 30,
      lesson_text: "Boundary: StockSage reflection reviewed by operator.",
      source: "stocksage_reflection",
      resolved_at: "2026-05-22"
    }
  end

  defp app_lesson_context do
    ReadyEffectContext.attach(%{
      user_id: "alice",
      actor: "alice",
      channel: :test,
      active_app: :stocksage,
      request: %{user_id: "alice", operator_id: "alice", channel: :test, active_app: :stocksage}
    })
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
