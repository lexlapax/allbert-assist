defmodule AllbertAssist.Workspace.CanvasTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.Canvas
  alias Jido.Signal.Bus

  test "tile CRUD persists metadata and YAML body" do
    thread_id = "thread-canvas-crud"
    user_id = "user-canvas-crud"

    assert {:ok, tile} =
             Canvas.add_tile(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :text,
               body: %{text: "draft", nested: %{count: 1}},
               metadata: %{source: "test"}
             })

    assert tile.body == %{"nested" => %{"count" => 1}, "text" => "draft"}
    assert tile.position == 0
    assert tile.body_yaml_path =~ "workspace/canvas/#{user_id}/#{thread_id}/"

    assert {:ok, [listed]} = Canvas.tiles_for_thread(thread_id, user_id)
    assert listed.id == tile.id
    assert listed.body["text"] == "draft"

    assert {:ok, updated} =
             Canvas.update_tile(tile.id, %{
               user_id: user_id,
               body: %{text: "updated"},
               size_width: 640
             })

    assert updated.size_width == 640
    assert updated.body == %{"text" => "updated"}
  end

  test "remove soft-deletes and restore brings a tile back at the end" do
    thread_id = "thread-canvas-restore"
    user_id = "user-canvas-restore"

    assert {:ok, first} = Canvas.add_tile(tile_attrs(thread_id, user_id, "first"))
    assert {:ok, second} = Canvas.add_tile(tile_attrs(thread_id, user_id, "second"))

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.tile.**")

    assert :ok = Canvas.remove_tile(first.id, user_id)
    removed = receive_signal("allbert.workspace.tile.removed")
    assert removed.data.tile_id == first.id
    assert removed.data.metadata.removed_reason == :operator_removed

    assert {:ok, [live]} = Canvas.tiles_for_thread(thread_id, user_id)
    assert live.id == second.id

    assert {:ok, deleted_and_live} =
             Canvas.tiles_for_thread(thread_id, user_id, include_deleted: true)

    assert Enum.any?(deleted_and_live, &(&1.id == first.id and not is_nil(&1.deleted_at)))
    assert Enum.any?(deleted_and_live, &(&1.id == first.id and &1.body_yaml_path =~ ".deleted."))

    assert {:ok, restored} = Canvas.restore_tile(first.id, user_id)
    restored_signal = receive_signal("allbert.workspace.tile.added")
    assert restored_signal.data.tile_id == first.id
    assert restored_signal.data.metadata.restored_from =~ ".deleted."

    assert is_nil(restored.deleted_at)
    assert restored.position > second.position
    assert restored.body["text"] == "first"
  end

  test "pin and unpin enforce user scope" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-pin", "user-pin", "pin me"))

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.tile.updated")

    assert {:error, :not_found} = Canvas.pin_tile(tile.id, "other-user")
    assert {:ok, pinned} = Canvas.pin_tile(tile.id, "user-pin")
    pinned_signal = receive_signal("allbert.workspace.tile.updated")
    assert pinned_signal.data.metadata.changed_fields == [:pinned]

    assert pinned.pinned == true

    assert {:ok, unpinned} = Canvas.unpin_tile(tile.id, "user-pin")
    unpinned_signal = receive_signal("allbert.workspace.tile.updated")
    assert unpinned_signal.data.metadata.changed_fields == [:pinned]

    assert unpinned.pinned == false
  end

  test "cap enforcement evicts the oldest non-pinned tile and preserves pinned tiles" do
    thread_id = "thread-canvas-cap"
    user_id = "user-canvas-cap"

    set_canvas_cap(3)

    tiles =
      for index <- 1..3 do
        assert {:ok, tile} = Canvas.add_tile(tile_attrs(thread_id, user_id, "tile #{index}"))
        tile
      end

    assert {:ok, pinned} = Canvas.pin_tile(Enum.at(tiles, 0).id, user_id)

    assert {:ok, _tile_subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.tile.removed")

    assert {:ok, _fragment_subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.fragment.emitted")

    assert {:ok, newest} = Canvas.add_tile(tile_attrs(thread_id, user_id, "overflow"))

    assert newest.body["text"] == "overflow"
    removed_signal = receive_signal("allbert.workspace.tile.removed")
    assert removed_signal.data.tile_id == Enum.at(tiles, 1).id
    assert removed_signal.data.metadata.removed_reason == :cap_evicted

    fragment_signal = receive_signal("allbert.workspace.fragment.emitted")
    assert fragment_signal.data.envelope.kind == :badge_strip
    assert fragment_signal.data.envelope.metadata.placement == "canvas_header"
    assert fragment_signal.data.envelope.metadata.removed_tile_id == Enum.at(tiles, 1).id

    assert {:ok, all_tiles} = Canvas.tiles_for_thread(thread_id, user_id, include_deleted: true)

    evicted = Enum.find(all_tiles, &(&1.id == Enum.at(tiles, 1).id))
    refute is_nil(evicted.deleted_at)
    assert evicted.body_yaml_path =~ ".deleted."

    still_live = Enum.find(all_tiles, &(&1.id == pinned.id))
    assert is_nil(still_live.deleted_at)
  end

  test "cap enforcement rejects when all tiles are pinned" do
    thread_id = "thread-canvas-all-pinned"
    user_id = "user-canvas-all-pinned"

    set_canvas_cap(3)

    for index <- 1..3 do
      assert {:ok, _tile} =
               Canvas.add_tile(
                 tile_attrs(thread_id, user_id, "tile #{index}")
                 |> Map.put(:pinned, true)
               )
    end

    assert {:error, :canvas_cap_exceeded} =
             Canvas.add_tile(tile_attrs(thread_id, user_id, "overflow"))
  end

  defp tile_attrs(thread_id, user_id, text) do
    %{thread_id: thread_id, user_id: user_id, kind: :text, body: %{text: text}}
  end

  defp set_canvas_cap(value) do
    assert {:ok, _setting} =
             Settings.put("workspace.canvas.max_tiles_per_thread", value, %{audit?: false})

    on_exit(fn ->
      Settings.put("workspace.canvas.max_tiles_per_thread", 64, %{audit?: false})
    end)
  end

  defp receive_signal(type) do
    receive do
      {:signal, %{type: ^type} = signal} -> signal
      {:signal, _signal} -> receive_signal(type)
    after
      1_000 -> flunk("expected signal #{type}")
    end
  end
end
