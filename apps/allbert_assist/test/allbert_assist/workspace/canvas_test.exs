defmodule AllbertAssist.Workspace.CanvasTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Workspace.Canvas

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

    assert :ok = Canvas.remove_tile(first.id, user_id)
    assert {:ok, [live]} = Canvas.tiles_for_thread(thread_id, user_id)
    assert live.id == second.id

    assert {:ok, deleted_and_live} =
             Canvas.tiles_for_thread(thread_id, user_id, include_deleted: true)

    assert Enum.any?(deleted_and_live, &(&1.id == first.id and not is_nil(&1.deleted_at)))

    assert {:ok, restored} = Canvas.restore_tile(first.id, user_id)
    assert is_nil(restored.deleted_at)
    assert restored.position > second.position
    assert restored.body["text"] == "first"
  end

  test "pin and unpin enforce user scope" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-pin", "user-pin", "pin me"))

    assert {:error, :not_found} = Canvas.pin_tile(tile.id, "other-user")
    assert {:ok, pinned} = Canvas.pin_tile(tile.id, "user-pin")
    assert pinned.pinned == true

    assert {:ok, unpinned} = Canvas.unpin_tile(tile.id, "user-pin")
    assert unpinned.pinned == false
  end

  test "cap enforcement evicts the oldest non-pinned tile and preserves pinned tiles" do
    thread_id = "thread-canvas-cap"
    user_id = "user-canvas-cap"

    tiles =
      for index <- 1..64 do
        assert {:ok, tile} = Canvas.add_tile(tile_attrs(thread_id, user_id, "tile #{index}"))
        tile
      end

    assert {:ok, pinned} = Canvas.pin_tile(Enum.at(tiles, 0).id, user_id)
    assert {:ok, newest} = Canvas.add_tile(tile_attrs(thread_id, user_id, "overflow"))

    assert newest.body["text"] == "overflow"
    assert {:ok, all_tiles} = Canvas.tiles_for_thread(thread_id, user_id, include_deleted: true)

    evicted = Enum.find(all_tiles, &(&1.id == Enum.at(tiles, 1).id))
    refute is_nil(evicted.deleted_at)

    still_live = Enum.find(all_tiles, &(&1.id == pinned.id))
    assert is_nil(still_live.deleted_at)
  end

  test "cap enforcement rejects when all tiles are pinned" do
    thread_id = "thread-canvas-all-pinned"
    user_id = "user-canvas-all-pinned"

    for index <- 1..64 do
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
end
