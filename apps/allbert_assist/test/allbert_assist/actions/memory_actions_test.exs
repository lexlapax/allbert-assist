defmodule AllbertAssist.Actions.MemoryActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Memory.ListMemoryEntries
  alias AllbertAssist.Actions.Memory.ReadMemoryEntry
  alias AllbertAssist.Memory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-memory-actions-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Memory, root: Path.join(home, "memory"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Memory, original_memory)
      restore_env(Settings, original_settings)
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
