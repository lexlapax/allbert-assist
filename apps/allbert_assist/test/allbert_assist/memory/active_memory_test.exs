defmodule AllbertAssist.Memory.ActiveMemoryTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.ActiveMemory
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @now "2026-05-28T12:00:00Z"

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_memory = Application.get_env(:allbert_assist, Memory)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-active-memory-#{System.unique_integer([:positive])}")

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

  test "retrieves kept identity and general chunks without neutral app leakage" do
    {:ok, identity} =
      Memory.upsert_system_entry(%{
        namespace: :identity,
        file_path: "persona.md",
        actor: "alice",
        summary: "Alice persona",
        body: "Alice prefers concise reports with concrete status."
      })

    {:ok, identity} = keep(identity)
    {:ok, general} = append("alice", "Concise reports should include release status.")
    {:ok, general} = keep(general)
    {:ok, unreviewed} = append("alice", "Unreviewed concise report detail.")
    {:ok, stocksage} = app_entry("alice", "StockSage concise report detail.")
    {:ok, stocksage} = keep(stocksage)

    assert {:ok, neutral} =
             ActiveMemory.retrieve("concise reports status",
               user_id: "alice",
               active_app: nil,
               now: @now
             )

    assert [first | _rest] = neutral.chunks
    assert first.entry_path == identity.path
    assert Enum.any?(neutral.chunks, &(&1.entry_path == general.path))
    refute Enum.any?(neutral.chunks, &(&1.entry_path == unreviewed.path))
    refute Enum.any?(neutral.chunks, &(&1.entry_path == stocksage.path))
    assert neutral.retrieved_chunks == Enum.map(neutral.chunks, &Map.drop(&1, [:body]))

    assert {:ok, app_scoped} =
             ActiveMemory.retrieve("stocksage concise report",
               user_id: "alice",
               active_app: :stocksage,
               now: @now
             )

    assert Enum.any?(app_scoped.chunks, &(&1.entry_path == stocksage.path))
  end

  test "defaults manually edited identity files to system identity metadata" do
    {:ok, entry} =
      Memory.append(%{
        category: :identity,
        body: "Identity reports should use direct language.",
        summary: "Manual identity",
        actor: "alice",
        agent: "test",
        channel: :test,
        source_signal_id: "sig"
      })

    assert {:ok, reviewed} = keep(entry)
    assert reviewed.origin == "system"
    assert reviewed.namespace == "identity"
    assert reviewed.app_id == nil

    assert {:ok, result} =
             ActiveMemory.retrieve("identity reports",
               user_id: "alice",
               active_app: nil,
               now: @now
             )

    assert [%{entry_path: path, origin: "system", namespace: "identity"}] = result.chunks
    assert path == reviewed.path
  end

  test "excludes identity-root files with conflicting app-owned metadata" do
    {:ok, entry} =
      Memory.append(%{
        category: :identity,
        body: "Conflicting StockSage identity reports should not surface.",
        summary: "Conflicting identity",
        actor: "alice",
        agent: "test",
        channel: :test,
        source_signal_id: "sig",
        origin: :app,
        app_id: :stocksage,
        namespace: :stocksage
      })

    {:ok, reviewed} = keep(entry)
    assert reviewed.category == :identity
    assert reviewed.app_id == "stocksage"

    assert {:ok, result} =
             ActiveMemory.retrieve("stocksage identity reports",
               user_id: "alice",
               active_app: :stocksage,
               now: @now
             )

    assert result.chunks == []
  end

  test "settings bound top-k, chunk size, and disabled retrieval" do
    body = String.duplicate("concise ", 80)
    {:ok, entry} = append("alice", body)
    {:ok, _entry} = keep(entry)

    assert {:ok, _setting} = Settings.put("active_memory.top_k", 1, %{audit?: false})
    assert {:ok, _setting} = Settings.put("active_memory.chunk_max_bytes", 128, %{audit?: false})

    assert {:ok, result} =
             ActiveMemory.retrieve("concise",
               user_id: "alice",
               active_app: nil,
               now: @now
             )

    assert length(result.chunks) == 1
    assert byte_size(List.first(result.chunks).body) <= 128

    assert {:ok, _setting} = Settings.put("active_memory.enabled", false, %{audit?: false})

    assert {:ok, disabled} =
             ActiveMemory.retrieve("concise",
               user_id: "alice",
               active_app: nil,
               now: @now
             )

    assert disabled.enabled? == false
    assert disabled.chunks == []
  end

  test "long kept entries are split into scored byte windows without ellipsis" do
    body = String.duplicate("anchor concise release reports ", 80)

    assert {:ok, entry} =
             Memory.upsert_system_entry(%{
               namespace: :identity,
               file_path: "long_persona.md",
               actor: "alice",
               summary: "Long persona",
               body: body
             })

    assert {:ok, _entry} = keep(entry)
    assert {:ok, _setting} = Settings.put("active_memory.top_k", 3, %{audit?: false})
    assert {:ok, _setting} = Settings.put("active_memory.chunk_max_bytes", 128, %{audit?: false})

    assert {:ok, first} =
             ActiveMemory.retrieve("anchor release reports",
               user_id: "alice",
               active_app: nil,
               now: @now
             )

    assert {:ok, second} =
             ActiveMemory.retrieve("anchor release reports",
               user_id: "alice",
               active_app: nil,
               now: @now
             )

    assert first.candidate_count_before_filter == 1
    assert first.candidate_chunk_count_before_filter > first.candidate_count_before_filter
    assert first.candidate_count_after_filter > 1
    assert length(first.chunks) == 3
    assert first.chunks == second.chunks

    for chunk <- first.chunks do
      assert String.starts_with?(chunk.chunk_id, "active_memory:")
      assert is_integer(chunk.chunk_index)
      assert byte_size(chunk.body) <= 128
      refute chunk.body =~ "..."
      refute chunk.body =~ "…"
    end
  end

  test "registered action returns deterministic body-bearing chunks and body-free metadata" do
    {:ok, entry} = append("alice", "Replayable concise reports for release reviews.")
    {:ok, _entry} = keep(entry)

    context = %{
      user_id: "alice",
      actor: "alice",
      channel: :test,
      thread_id: "thr_active",
      request: %{request_started_at: @now}
    }

    params = %{query: "concise reports"}

    assert {:ok, first} = Runner.run("retrieve_active_memory", params, context)
    assert {:ok, second} = Runner.run("retrieve_active_memory", params, context)

    assert first.status == :completed
    assert first.chunks == second.chunks
    assert [%{body: body}] = first.chunks
    assert body =~ "Replayable concise"

    metadata_chunks =
      first.actions
      |> List.first()
      |> get_in([:active_memory, :retrieved_chunks])

    assert Enum.all?(metadata_chunks, &(not Map.has_key?(&1, :body)))
  end

  test "replayability fixture returns byte-identical chunks for same state", %{home: home} do
    fixture = Path.expand("../../fixtures/v0.39b/active_memory_identity.md", __DIR__)
    destination = Path.join([home, "memory", "identity", "active_memory_identity.md"])

    File.mkdir_p!(Path.dirname(destination))
    File.cp!(fixture, destination)

    opts = [user_id: "alice", active_app: nil, now: @now]

    assert {:ok, first} = ActiveMemory.retrieve("concise release reports", opts)
    assert {:ok, second} = ActiveMemory.retrieve("concise release reports", opts)

    assert first.chunks != []
    assert :erlang.term_to_binary(first.chunks) == :erlang.term_to_binary(second.chunks)

    assert :erlang.term_to_binary(first.retrieved_chunks) ==
             :erlang.term_to_binary(second.retrieved_chunks)
  end

  defp append(actor, body) do
    Memory.append(%{
      category: :notes,
      body: body,
      summary: body,
      actor: actor,
      agent: "test",
      channel: :test,
      source_signal_id: "sig"
    })
  end

  defp app_entry(actor, body) do
    Memory.append(%{
      category: :notes,
      body: body,
      summary: body,
      actor: actor,
      agent: "test",
      channel: :test,
      source_signal_id: "sig",
      app_id: :stocksage,
      namespace: :stocksage,
      kind: :stocksage_lesson,
      source_ref: "stocksage:analysis:example"
    })
  end

  defp keep(entry) do
    Memory.review_entry(
      entry.path,
      %{status: :kept, reviewed_at: @now, reviewed_by: entry.actor},
      user_id: entry.actor
    )
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
