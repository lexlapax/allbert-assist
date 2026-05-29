defmodule AllbertAssist.Memory.CompilerTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Compiler
  alias AllbertAssist.Paths

  setup do
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-memory-compiler-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "compile_index handles an empty memory root" do
    assert {:ok, result} = Compiler.compile_index(Memory.root())

    assert result.entry_count == 0
    assert result.categories == []
    assert File.read!(result.path) =~ "# DERIVED - DO NOT EDIT"
  end

  test "summarize_category writes a summary when no kept entries exist" do
    assert {:ok, _entry} =
             Memory.append(%{
               category: :notes,
               body: "A note that has not been reviewed yet.",
               actor: "alice",
               agent: "test",
               channel: :test,
               source_signal_id: "sig"
             })

    assert {:ok, result} = Compiler.summarize_category(Memory.root(), :notes, user_id: "alice")

    summary = File.read!(result.path)
    assert summary =~ "# DERIVED - DO NOT EDIT"
    assert summary =~ "Memory Summary: notes"
    assert summary =~ "Recently Reviewed Kept Entries"
    assert summary =~ "(none)"
  end

  test "summarize_category rejects invalid categories" do
    assert {:error, :invalid_category} = Compiler.summarize_category(Memory.root(), "notes")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
