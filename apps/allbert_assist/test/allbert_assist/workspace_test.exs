defmodule AllbertAssist.WorkspaceTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Ephemeral

  test "facade delegates canvas and ephemeral calls" do
    thread_id = "thread-facade"
    user_id = "user-facade"

    assert {:ok, tile} =
             Workspace.add_tile(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :text,
               body: %{text: "hello"}
             })

    assert {:ok, [listed]} = Workspace.canvas_tiles(thread_id, user_id)
    assert listed.id == tile.id

    assert {:ok, ephemeral} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{text: "approve?"}
             })

    assert {:ok, [listed_ephemeral]} = Workspace.ephemeral_surfaces(thread_id, user_id)
    assert listed_ephemeral.id == ephemeral.id
  end
end
