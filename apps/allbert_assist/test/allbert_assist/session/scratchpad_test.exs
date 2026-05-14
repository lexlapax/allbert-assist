defmodule AllbertAssist.Session.ScratchpadTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Session
  alias AllbertAssist.Session.Scratchpad

  setup do
    name = :"scratchpad_#{System.unique_integer([:positive])}"
    table = :"scratchpad_table_#{System.unique_integer([:positive])}"

    start_scratchpad!(name, table_name: table, ttl_ms: 120_000, sweep_interval_ms: 0)

    {:ok, opts: [server: name]}
  end

  test "creates, gets, lists, and clears entries without crossing users", %{opts: opts} do
    assert {:ok, entry} = Session.set_active_app("alice", "sess-1", :stocksage, opts)
    assert entry.user_id == "alice"
    assert entry.session_id == "sess-1"
    assert entry.active_app == :stocksage

    assert {:ok, fetched} = Session.get("alice", "sess-1", opts)
    assert fetched.active_app == :stocksage

    assert {:ok, [listed]} = Session.list("alice", opts)
    assert listed.session_id == "sess-1"

    assert {:ok, []} = Session.list("bob", opts)
    assert {:error, :not_found} = Session.get("bob", "sess-1", opts)

    assert {:ok, %{removed?: true}} = Session.clear("alice", "sess-1", opts)
    assert {:error, :not_found} = Session.get("alice", "sess-1", opts)
  end

  test "normalizes and rejects invalid user and session ids", %{opts: opts} do
    assert {:ok, entry} = Session.set_active_app(" alice ", " sess-1 ", :stocksage, opts)
    assert entry.user_id == "alice"
    assert entry.session_id == "sess-1"

    assert {:error, :invalid_user_id} =
             Session.set_active_app(" ", "sess-1", :stocksage, opts)

    assert {:error, :invalid_session_id} =
             Session.set_active_app("alice", " ", :stocksage, opts)

    too_long = String.duplicate("s", Session.max_session_id_length() + 1)

    assert {:error, :session_id_too_long} =
             Session.set_active_app("alice", too_long, :stocksage, opts)
  end

  test "clear_active_app preserves working memory while extending the entry", %{opts: opts} do
    assert {:ok, _entry} = Session.set_active_app("alice", "sess-1", :stocksage, opts)
    assert {:ok, _entry} = Session.merge_working_memory("alice", "sess-1", %{pane: "left"}, opts)

    assert {:ok, entry} = Session.clear_active_app("alice", "sess-1", opts)
    assert entry.active_app == nil
    assert entry.working_memory == %{pane: "left"}

    assert Session.summary(entry).working_memory_keys == ["pane"]
    assert Session.summary(entry).working_memory_key_count == 1
  end

  test "merge_working_memory is shallow and rejects reserved or oversized payloads", %{opts: opts} do
    assert {:ok, entry} =
             Session.merge_working_memory("alice", "sess-1", %{pane: "left"}, opts)

    assert entry.working_memory == %{pane: "left"}

    assert {:ok, entry} =
             Session.merge_working_memory("alice", "sess-1", %{pane: "right"}, opts)

    assert entry.working_memory == %{pane: "right"}

    assert {:error, :reserved_key} =
             Session.merge_working_memory("alice", "sess-1", %{canvas_tiles: []}, opts)

    assert {:error, :reserved_key} =
             Session.merge_working_memory("alice", "sess-1", %{"canvas_tiles" => []}, opts)

    assert {:error, :sensitive_working_memory_key} =
             Session.merge_working_memory("alice", "sess-1", %{api_key: "nope"}, opts)

    large_payload = %{large: String.duplicate("x", 70_000)}

    assert {:error, :working_memory_too_large} =
             Session.merge_working_memory("alice", "sess-1", large_payload, opts)
  end

  test "expires entries, sweeps them, and touch extends the live ttl" do
    name = :"scratchpad_expiry_#{System.unique_integer([:positive])}"
    table = :"scratchpad_expiry_table_#{System.unique_integer([:positive])}"

    start_scratchpad!(name, table_name: table, ttl_ms: 80, sweep_interval_ms: 0)

    opts = [server: name]
    assert {:ok, _entry} = Session.set_active_app("alice", "short", :stocksage, opts)
    Process.sleep(40)
    assert {:ok, _entry} = Session.touch("alice", "short", opts)
    Process.sleep(50)
    assert {:ok, entry} = Session.get("alice", "short", opts)
    assert entry.active_app == :stocksage

    Process.sleep(90)
    assert {:error, :not_found} = Session.get("alice", "short", opts)

    assert {:ok, _entry} = Session.set_active_app("alice", "expired", :stocksage, opts)
    Process.sleep(90)
    assert {:ok, 1} = Session.sweep_expired(opts)
    assert {:ok, []} = Session.list("alice", opts)
  end

  test "restart starts with an empty table" do
    name = :"scratchpad_restart_#{System.unique_integer([:positive])}"
    table = :"scratchpad_restart_table_#{System.unique_integer([:positive])}"

    child = scratchpad_child_spec(name, table_name: table, ttl_ms: 120_000, sweep_interval_ms: 0)

    start_supervised!(child)
    opts = [server: name]

    assert {:ok, _entry} = Session.set_active_app("alice", "sess-1", :stocksage, opts)
    assert {:ok, _entry} = Session.get("alice", "sess-1", opts)

    stop_supervised!(name)
    start_supervised!(child)

    assert {:error, :not_found} = Session.get("alice", "sess-1", opts)
  end

  test "disabled scratchpad reads as empty and rejects writes" do
    name = :"scratchpad_disabled_#{System.unique_integer([:positive])}"

    start_scratchpad!(name, enabled?: false, table_name: :unused_table, sweep_interval_ms: 0)

    opts = [server: name]

    assert {:error, :not_found} = Session.get("alice", "sess-1", opts)
    assert {:ok, []} = Session.list("alice", opts)
    assert {:ok, 0} = Session.sweep_expired(opts)
    assert {:error, :disabled} = Session.set_active_app("alice", "sess-1", :stocksage, opts)
  end

  defp start_scratchpad!(name, opts) do
    name
    |> scratchpad_child_spec(opts)
    |> start_supervised!()
  end

  defp scratchpad_child_spec(name, opts) do
    opts = Keyword.put(opts, :name, name)
    Supervisor.child_spec({Scratchpad, opts}, id: name)
  end
end
