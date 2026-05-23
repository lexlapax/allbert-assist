defmodule AllbertAssist.MemoryTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Memory

  setup do
    original_config = Application.get_env(:allbert_assist, Memory)

    root =
      Path.join(System.tmp_dir!(), "allbert-memory-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Memory, root: root)

    on_exit(fn ->
      if original_config do
        Application.put_env(:allbert_assist, Memory, original_config)
      else
        Application.delete_env(:allbert_assist, Memory)
      end

      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "creates the memory root and initial categories", %{root: root} do
    assert Memory.ensure_root!() == root

    for category <- Memory.categories() do
      assert File.dir?(Path.join(root, Atom.to_string(category)))
    end
  end

  test "appends human-readable markdown memory", %{root: root} do
    assert {:ok, entry} =
             Memory.append(%{
               category: :notes,
               body: "My planning docs should be implementation-ready.",
               source_signal_id: "sig-123",
               actor: "local",
               agent: "AllbertAssist.Agents.IntentAgent",
               channel: :test
             })

    assert entry.path =~ Path.join(root, "notes")
    assert File.exists?(entry.path)

    markdown = File.read!(entry.path)
    assert markdown =~ "# Memory: My planning docs should be implementation-ready."
    assert markdown =~ "- Source signal: sig-123"
    assert markdown =~ "- Actor: local"
    assert markdown =~ "- Agent: AllbertAssist.Agents.IntentAgent"
    assert markdown =~ "## Body"
    assert markdown =~ "My planning docs should be implementation-ready."
  end

  test "upserts namespaced app memory entries idempotently", %{root: root} do
    ensure_stocksage_registered()

    attrs = %{
      category: :notes,
      app_id: :stocksage,
      namespace: :stocksage,
      kind: :stocksage_lesson,
      idempotency_key: "analysis-1:outcome-1",
      source_ref: "stocksage:analysis:analysis-1",
      actor: "alice",
      agent: "test",
      channel: :test,
      source_signal_id: "sig-app",
      summary: "AAPL lesson",
      body: "Initial lesson body."
    }

    assert {:ok, entry} = Memory.upsert_app_entry(attrs)
    assert entry.path =~ Path.join(root, "notes")
    assert entry.app_id == "stocksage"
    assert entry.namespace == "stocksage"
    assert entry.kind == "stocksage_lesson"
    assert entry.idempotency_key == "analysis-1:outcome-1"
    assert entry.source_ref == "stocksage:analysis:analysis-1"

    markdown = File.read!(entry.path)
    assert markdown =~ "- App ID: stocksage"
    assert markdown =~ "- Namespace: stocksage"
    assert markdown =~ "- Kind: stocksage_lesson"
    assert markdown =~ "- Idempotency key: analysis-1:outcome-1"
    assert markdown =~ "- Source ref: stocksage:analysis:analysis-1"

    assert {:ok, [listed]} =
             Memory.list_entries(
               user_id: "alice",
               app_id: :stocksage,
               namespace: :stocksage,
               kind: :stocksage_lesson,
               idempotency_key: "analysis-1:outcome-1"
             )

    assert listed.path == entry.path

    assert {:ok, updated} =
             Memory.upsert_app_entry(%{
               attrs
               | summary: "Updated AAPL lesson",
                 body: "Updated lesson body."
             })

    assert updated.path == entry.path
    assert updated.body == "Updated lesson body."

    assert {:ok, [only_entry]} =
             Memory.list_entries(user_id: "alice", app_id: "stocksage", namespace: "stocksage")

    assert only_entry.path == entry.path
  end

  test "namespaced app memory requires a writable registered namespace" do
    ensure_stocksage_registered()

    assert {:error, {:unknown_memory_namespace, :unknown_namespace}} =
             Memory.upsert_app_entry(%{
               app_id: :stocksage,
               namespace: :unknown_namespace,
               kind: :stocksage_lesson,
               idempotency_key: "missing",
               source_ref: "stocksage:analysis:missing",
               actor: "alice",
               body: "Should not be written."
             })
  end

  test "reads recent markdown memory ranked by query" do
    assert {:ok, _entry} =
             Memory.append(%{
               category: :notes,
               body: "My planning docs should be implementation-ready.",
               source_signal_id: "sig-123",
               actor: "local",
               agent: "AllbertAssist.Agents.IntentAgent",
               channel: :test
             })

    assert {:ok, entries} = Memory.recent(query: "What do you remember about my planning docs?")

    assert [%{body: body, summary: summary} | _rest] = entries
    assert body =~ "planning docs"
    assert summary =~ "planning docs"
  end

  test "recent memory excludes trace entries unless requested" do
    assert {:ok, _trace} =
             Memory.append(%{
               category: :traces,
               body: "Trace for a concise milestone handoff memory write.",
               source_signal_id: "sig-trace",
               actor: "local",
               agent: "AllbertAssist.Runtime",
               channel: :test
             })

    assert {:ok, _preference} =
             Memory.append(%{
               category: :preferences,
               body: "I like concise milestone handoffs.",
               source_signal_id: "sig-pref",
               actor: "local",
               agent: "AllbertAssist.Agents.IntentAgent",
               channel: :test
             })

    assert {:ok, entries} = Memory.recent(query: "milestone handoffs")

    assert Enum.all?(entries, &(&1.category != :traces))
    assert [%{category: :preferences}] = entries

    assert {:ok, trace_entries} =
             Memory.recent(query: "milestone handoffs", categories: [:traces])

    assert [%{category: :traces}] = trace_entries
  end

  defp ensure_stocksage_registered do
    unless AppRegistry.known_app_id?(:stocksage) do
      assert AppRegistry.register(StockSage.App) in [
               {:ok, :stocksage},
               {:error, {:app_id_taken, :stocksage}}
             ]
    end
  end
end
