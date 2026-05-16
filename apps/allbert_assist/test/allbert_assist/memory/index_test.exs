defmodule AllbertAssist.Memory.IndexTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Compiler
  alias AllbertAssist.Memory.Index
  alias AllbertAssist.Paths

  setup do
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-memory-index-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "compile_index writes a derived JSON index and query loads matching entries" do
    assert {:ok, _entry} =
             Memory.append(%{
               category: :preferences,
               body: "Alice prefers concise release notes.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "sig"
             })

    assert {:ok, result} = Compiler.compile_index(Memory.root())
    assert result.entry_count == 1
    assert File.read!(result.path) =~ "# DERIVED - DO NOT EDIT"
    refute Index.stale?(Memory.root())

    assert {:ok, index} = Index.load(Memory.root())

    assert {:ok, [%{summary: summary, match_reasons: reasons}]} =
             Index.query(index, "concise notes", user_id: "alice")

    assert summary =~ "Alice prefers concise"
    assert "keyword:concise" in reasons
  end

  test "query scores are capped at the v0.21 memory candidate ceiling" do
    assert {:ok, _entry} =
             Memory.append(%{
               category: :preferences,
               body: "Alice wants concise compact release notes with compact concise summaries.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "sig"
             })

    assert {:ok, _result} = Compiler.compile_index(Memory.root())
    assert {:ok, index} = Index.load(Memory.root())

    assert {:ok, [%{score: score}]} =
             Index.query(index, "concise compact release notes summaries", user_id: "alice")

    assert score <= 0.5
  end

  test "summarize_category writes a derived markdown summary" do
    assert {:ok, entry} =
             Memory.append(%{
               category: :notes,
               body: "A useful body",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "sig"
             })

    assert {:ok, _reviewed} =
             Memory.review_entry(entry.path, %{status: :kept, reviewed_by: "alice"},
               user_id: "alice"
             )

    assert {:ok, result} = Compiler.summarize_category(Memory.root(), :notes, user_id: "alice")
    content = File.read!(result.path)

    assert content =~ "# DERIVED - DO NOT EDIT"
    assert content =~ "Memory Summary: notes"
    assert content =~ "A useful body"
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
