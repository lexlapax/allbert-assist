defmodule AllbertAssist.MemoryTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.Memory
  alias AllbertAssist.Memory.Namespaces
  alias AllbertAssist.Memory.SystemNamespaces
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

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
    assert :identity in Memory.categories()

    for category <- Memory.categories() do
      assert File.dir?(Path.join(root, Atom.to_string(category)))
    end
  end

  test "declares identity as an operator-owned system namespace" do
    assert [%{namespace: :identity, origin: :system, app_id: nil, category: :identity}] =
             SystemNamespaces.all()

    assert {:ok, %{writable: true, description: description}} =
             Namespaces.system_namespace(:identity)

    assert description =~ "identity"
    refute AppRegistry.known_app_id?(:_system)
  end

  test "combined namespace facade merges app and system declarations" do
    ensure_stocksage_registered()

    namespaces = Namespaces.all()

    assert Enum.any?(
             namespaces,
             &match?(%{origin: :system, app_id: nil, namespace: :identity}, &1)
           )

    assert Enum.any?(
             namespaces,
             &match?(%{origin: :app, app_id: :stocksage, namespace: :stocksage}, &1)
           )
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

  test "upserts system identity memory entries idempotently", %{root: root} do
    attrs = %{
      namespace: :identity,
      file_path: "persona.md",
      kind: :persona,
      actor: "alice",
      agent: "test",
      channel: :test,
      source_signal_id: "sig-identity",
      summary: "Alice persona",
      body: "Call me Alice and keep answers concise."
    }

    assert {:ok, entry} = Memory.upsert_system_entry(attrs)
    assert entry.path == Path.join([root, "identity", "persona.md"])
    assert entry.category == :identity
    assert entry.origin == "system"
    assert entry.app_id == nil
    assert entry.namespace == "identity"
    assert entry.kind == "persona"
    assert entry.idempotency_key == "persona.md"
    assert entry.source_ref == "system:identity:persona.md"

    markdown = File.read!(entry.path)
    assert markdown =~ "- Origin: system"
    assert markdown =~ "- Namespace: identity"
    refute markdown =~ "- App ID:"

    assert {:ok, updated} =
             Memory.upsert_system_entry(%{
               attrs
               | summary: "Updated persona",
                 body: "Call me Alice and prefer concise answers."
             })

    assert updated.path == entry.path
    assert updated.body == "Call me Alice and prefer concise answers."

    assert {:ok, [listed]} =
             Memory.list_entries(user_id: "alice", category: :identity, namespace: :identity)

    assert listed.path == entry.path
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

  test "system identity memory rejects unknown namespaces and unsafe paths" do
    assert {:error, {:unknown_memory_namespace, :unknown_namespace}} =
             Memory.upsert_system_entry(%{
               namespace: :unknown_namespace,
               file_path: "persona.md",
               body: "Unknown system namespace."
             })

    assert {:error, :path_outside_memory_root} =
             Memory.upsert_system_entry(%{
               namespace: :identity,
               file_path: "../outside.md",
               body: "Traversal attempt."
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
end
