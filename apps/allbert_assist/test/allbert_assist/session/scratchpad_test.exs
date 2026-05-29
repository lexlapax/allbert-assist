defmodule AllbertAssist.Session.ScratchpadTest do
  use ExUnit.Case, async: false
  @moduletag :global_process_serial

  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Session
  alias AllbertAssist.Session.AppId
  alias AllbertAssist.Session.Scratchpad

  setup do
    name = :"scratchpad_#{System.unique_integer([:positive])}"
    table = :"scratchpad_table_#{System.unique_integer([:positive])}"
    registered? = AllbertAssist.App.Registry.known_app_id?(:stocksage)
    ensure_stocksage_plugin!()

    unless registered? do
      assert {:ok, :stocksage} = AllbertAssist.App.Registry.register(StockSage.App)
    end

    start_scratchpad!(name, table_name: table, ttl_ms: 120_000, sweep_interval_ms: 0)

    on_exit(fn ->
      unless registered?, do: AllbertAssist.App.Registry.unregister(:stocksage)
    end)

    {:ok, opts: [server: name]}
  end

  defp ensure_stocksage_plugin! do
    case PluginRegistry.lookup("stocksage") do
      {:ok, _entry} ->
        :ok

      {:error, :not_found} ->
        assert {:ok, "stocksage"} = PluginRegistry.register_module(StockSage.Plugin)
    end
  end

  test "AppId registry normalizes known apps and never creates unknown atoms" do
    assert {:ok, :allbert} = AppId.normalize(:allbert)
    assert {:ok, :stocksage} = AppId.normalize("stocksage")
    assert {:ok, nil} = AppId.normalize("")
    assert {:ok, nil} = AppId.normalize("none")
    assert {:ok, nil} = AppId.normalize("general")
    assert {:error, :unknown_app} = AppId.normalize(:unknown_app)

    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"
    assert {:error, :unknown_app} = AppId.normalize(unknown)

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end
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

  test "put creates and updates selected entry fields", %{opts: opts} do
    assert {:ok, entry} =
             Session.put(
               "alice",
               "sess-1",
               %{
                 active_app: "stocksage",
                 working_memory: %{pane: "left"},
                 metadata: %{source: "test"}
               },
               opts
             )

    assert entry.active_app == :stocksage
    assert entry.working_memory == %{pane: "left"}
    assert entry.metadata == %{source: "test"}

    assert {:ok, updated} =
             Session.put("alice", "sess-1", %{"metadata" => %{"origin" => "cli"}}, opts)

    assert updated.active_app == :stocksage
    assert updated.working_memory == %{pane: "left"}
    assert updated.metadata == %{"origin" => "cli"}
  end

  test "put rejects invalid metadata maps", %{opts: opts} do
    for key <- [:secret, :token, :password, :credential, :api_key] do
      assert {:error, :sensitive_metadata_key} =
               Session.put("alice", "sess-#{key}", %{metadata: %{key => "nope"}}, opts)
    end

    large_payload = %{large: String.duplicate("x", 20_000)}

    assert {:error, :metadata_too_large} =
             Session.put("alice", "sess-large", %{metadata: large_payload}, opts)
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

    for key <- [:secret, :token, :password, :credential, :api_key] do
      assert {:error, :sensitive_working_memory_key} =
               Session.merge_working_memory("alice", "sess-#{key}", %{key => "nope"}, opts)
    end

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

  test "clear_active_app on an expired entry returns not_found" do
    name = :"scratchpad_clear_expired_#{System.unique_integer([:positive])}"
    table = :"scratchpad_clear_expired_table_#{System.unique_integer([:positive])}"

    start_scratchpad!(name, table_name: table, ttl_ms: 30, sweep_interval_ms: 0)

    opts = [server: name]
    assert {:ok, _entry} = Session.set_active_app("alice", "expired", :stocksage, opts)

    Process.sleep(40)

    assert {:error, :not_found} = Session.clear_active_app("alice", "expired", opts)
    assert {:error, :not_found} = Session.get("alice", "expired", opts)
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
