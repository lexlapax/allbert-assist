defmodule AllbertAssist.Workspace.ManageTileActionTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-manage-tile-test-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

  test "manages tiles through the action boundary and enforces thread scope" do
    user_id = "user-manage-tile"

    assert {:ok, tile} =
             Workspace.add_tile(%{
               user_id: user_id,
               thread_id: "thread-one",
               kind: :text,
               body: %{text: "first tile"}
             })

    assert {:ok, other_tile} =
             Workspace.add_tile(%{
               user_id: user_id,
               thread_id: "thread-two",
               kind: :text,
               body: %{text: "second tile"}
             })

    context = %{actor: user_id, user_id: user_id, thread_id: "thread-one", channel: :live_view}

    assert {:ok, %{status: :completed, operation: :pin}} =
             Runner.run("manage_workspace_tile", %{tile_id: tile.id, operation: "pin"}, context)

    assert {:ok, pinned} = Workspace.get_tile(tile.id, user_id)
    assert pinned.pinned == true

    assert {:ok, %{status: :denied, reason: :tile_thread_mismatch}} =
             Runner.run(
               "manage_workspace_tile",
               %{tile_id: other_tile.id, operation: "pin"},
               context
             )

    assert {:ok, untouched} = Workspace.get_tile(other_tile.id, user_id)
    assert untouched.pinned == false
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
