defmodule Mix.Tasks.Allbert.MemoryTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Memory, as: MemoryTask

  setup do
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-memory-cli-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      Mix.Task.reenable("allbert.memory")
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "list and show render stable memory output" do
    assert {:ok, entry} =
             Memory.append(%{
               category: :preferences,
               body: "Alice prefers concise updates.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "sig"
             })

    list_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["list", "--user", "alice", "--category", "preferences"])
      end)

    assert list_output =~ "preferences"
    assert list_output =~ "unreviewed"
    assert list_output =~ "Alice prefers concise updates."
    assert list_output =~ entry.path

    Mix.Task.reenable("allbert.memory")

    show_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["show", entry.path, "--user", "alice"])
      end)

    assert show_output =~ "Review status: unreviewed"
    assert show_output =~ "Alice prefers concise updates."
  end

  test "status reports exact review-status counts and the memory root" do
    assert {:ok, _unreviewed} =
             Memory.append(%{
               category: :notes,
               body: "Unreviewed candidate.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "s1"
             })

    assert {:ok, kept} =
             Memory.append(%{
               category: :notes,
               body: "Kept candidate.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "s2"
             })

    assert {:ok, flagged} =
             Memory.append(%{
               category: :preferences,
               body: "Flagged candidate.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "s3"
             })

    assert {:ok, _} =
             Memory.review_entry(kept.path, %{status: :kept, reviewed_by: "alice"},
               user_id: "alice"
             )

    assert {:ok, _} =
             Memory.review_entry(flagged.path, %{status: :flagged, reviewed_by: "alice"},
               user_id: "alice"
             )

    output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["status"])
      end)

    assert output =~ "unreviewed=1"
    assert output =~ "kept=1"
    assert output =~ "flagged=1"
    assert output =~ "prune_nominated=0"
    assert output =~ "total=3"
    assert output =~ "root="
  end

  test "empty list prints an empty-state message" do
    output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["list", "--user", "alice"])
      end)

    assert output =~ "No memory entries."
  end

  test "review, update, delete, and prune run through CLI action surfaces" do
    assert {:ok, entry} =
             Memory.append(%{
               category: :notes,
               body: "Alice prefers terse milestone notes.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "sig"
             })

    review_output =
      capture_io(fn ->
        assert :ok =
                 MemoryTask.run([
                   "review",
                   entry.path,
                   "--status",
                   "prune_nominated",
                   "--note",
                   "duplicate",
                   "--user",
                   "alice"
                 ])
      end)

    assert review_output =~ "reviewed:"
    assert review_output =~ "Review status: prune_nominated"

    Mix.Task.reenable("allbert.memory")

    update_output =
      capture_io(fn ->
        assert :ok =
                 MemoryTask.run([
                   "update",
                   entry.path,
                   "--summary",
                   "Terse milestone notes",
                   "--user",
                   "alice"
                 ])
      end)

    assert update_output =~ "updated:"
    assert update_output =~ "Terse milestone notes"

    Mix.Task.reenable("allbert.memory")

    prune_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["prune", "--user", "alice"])
      end)

    assert prune_output =~ "Candidate count: 1"
    assert prune_output =~ "prune_nominated"

    Mix.Task.reenable("allbert.memory")

    delete_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["delete", entry.path, "--user", "alice"])
      end)

    assert delete_output =~ "Confirmation:"
    assert delete_output =~ "No file was moved."
    assert File.exists?(entry.path)
  end

  test "compile-index, search, and summarize render operator output" do
    assert {:ok, _entry} =
             Memory.append(%{
               category: :preferences,
               body: "Alice prefers concise release summaries.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "sig"
             })

    compile_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["compile-index", "--user", "alice"])
      end)

    assert compile_output =~ "Index:"
    assert compile_output =~ "Entries: 1"

    Mix.Task.reenable("allbert.memory")

    search_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["search", "concise release", "--user", "alice"])
      end)

    assert search_output =~ "preferences"
    assert search_output =~ "Alice prefers concise"

    Mix.Task.reenable("allbert.memory")

    summary_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["summarize", "--category", "preferences", "--user", "alice"])
      end)

    assert summary_output =~ "Summary:"
    assert summary_output =~ "Entries: 1"
  end

  test "list filters identity namespace and retrieve prints deterministic chunks" do
    assert {:ok, entry} =
             Memory.upsert_system_entry(%{
               namespace: :identity,
               file_path: "persona.md",
               actor: "alice",
               summary: "Alice persona",
               body: "Alice prefers concise release reports."
             })

    assert {:ok, entry} =
             Memory.review_entry(
               entry.path,
               %{
                 status: :kept,
                 reviewed_at: "2026-05-28T12:00:00Z",
                 reviewed_by: "alice"
               },
               user_id: "alice"
             )

    namespace_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["list", "--user", "alice", "--namespace", "identity"])
      end)

    assert namespace_output =~ "identity"
    assert namespace_output =~ entry.path

    Mix.Task.reenable("allbert.memory")

    category_output =
      capture_io(fn ->
        assert :ok = MemoryTask.run(["list", "--user", "alice", "--category", "identity"])
      end)

    assert category_output =~ entry.path

    Mix.Task.reenable("allbert.memory")

    retrieve_output =
      capture_io(fn ->
        assert :ok =
                 MemoryTask.run([
                   "retrieve",
                   "--query",
                   "concise release reports",
                   "--user",
                   "alice",
                   "--now",
                   "2026-05-28T12:00:00Z"
                 ])
      end)

    assert retrieve_output =~ "Active Memory chunks: 1"
    assert retrieve_output =~ "score="
    assert retrieve_output =~ "recency="
    assert retrieve_output =~ "identity=1.5"
    assert retrieve_output =~ entry.path
  end

  test "quick smoke retrieves a plain identity markdown file", %{home: home} do
    path = Path.join([home, "memory", "identity", "persona.md"])

    File.mkdir_p!(Path.dirname(path))

    File.write!(path, """
    # Persona

    I prefer concise release reports with clear validation notes.
    """)

    review_output =
      capture_io(fn ->
        assert :ok =
                 MemoryTask.run([
                   "review",
                   path,
                   "--user",
                   "local",
                   "--status",
                   "kept",
                   "--note",
                   "Operator-authored identity"
                 ])
      end)

    assert review_output =~ "reviewed:"
    assert review_output =~ "Review status: kept"

    Mix.Task.reenable("allbert.memory")

    retrieve_output =
      capture_io(fn ->
        assert :ok =
                 MemoryTask.run([
                   "retrieve",
                   "--user",
                   "local",
                   "--query",
                   "concise release reports",
                   "--now",
                   "2026-05-28T12:00:00Z"
                 ])
      end)

    assert retrieve_output =~ "Active Memory chunks: 1"
    assert retrieve_output =~ "namespace=identity"
    assert retrieve_output =~ path
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
