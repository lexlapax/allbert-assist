defmodule AllbertAssist.Actions.MemoryActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Memory.CompileMemoryIndex
  alias AllbertAssist.Actions.Memory.DeleteMemoryEntry
  alias AllbertAssist.Actions.Memory.ListMemoryEntries
  alias AllbertAssist.Actions.Memory.PruneMemoryEntries
  alias AllbertAssist.Actions.Memory.ReadMemoryEntry
  alias AllbertAssist.Actions.Memory.ReviewMemoryEntry
  alias AllbertAssist.Actions.Memory.SearchMemory
  alias AllbertAssist.Actions.Memory.SummarizeMemoryCategory
  alias AllbertAssist.Actions.Memory.SyncAppLesson
  alias AllbertAssist.Actions.Memory.UpdateMemoryEntry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
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

  test "sync_app_lesson requires confirmation before writing namespaced app memory" do
    ensure_stocksage_registered()
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
               %{
                 user_id: "alice",
                 actor: "alice",
                 channel: :test
               }
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
    ensure_stocksage_registered()

    assert {:ok, response} =
             SyncAppLesson.run(
               %{app_lesson_params() | namespace: "unclaimed"},
               Map.put(app_lesson_context(), :confirmation, %{approved?: true})
             )

    assert response.status == :error
    assert response.error == {:unknown_memory_namespace, :unclaimed}
  end

  test "sync_app_lesson caps and redacts oversized lesson text before writing" do
    ensure_stocksage_registered()

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
    %{
      user_id: "alice",
      actor: "alice",
      channel: :test,
      active_app: :stocksage,
      request: %{user_id: "alice", operator_id: "alice", channel: :test, active_app: :stocksage}
    }
  end

  defp ensure_stocksage_registered do
    assert PluginRegistry.register_module(StockSage.Plugin) in [
             {:ok, "stocksage"},
             {:error, {:plugin_id_taken, "stocksage"}}
           ]

    unless AppRegistry.known_app_id?(:stocksage) do
      assert AppRegistry.register(StockSage.App) in [
               {:ok, :stocksage},
               {:error, {:app_id_taken, :stocksage}}
             ]
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
