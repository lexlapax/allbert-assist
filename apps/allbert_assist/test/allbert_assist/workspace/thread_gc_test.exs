defmodule AllbertAssist.Workspace.ThreadGCTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Conversations
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Ephemeral
  alias Jido.Signal.Bus

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    home = Path.join(System.tmp_dir!(), "allbert-thread-gc-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

  test "thread completion dismisses ephemerals and leaves canvas tiles read-only" do
    assert {:ok, thread} = Conversations.create_general_thread("alice", "Close me")

    assert {:ok, surface} =
             Ephemeral.open(%{
               thread_id: thread.id,
               user_id: thread.user_id,
               kind: :approval_card,
               body: %{title: "Approve"}
             })

    assert {:ok, tile} =
             Canvas.add_tile(%{
               thread_id: thread.id,
               user_id: thread.user_id,
               kind: :text,
               body: %{text: "keep this"}
             })

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.ephemeral.closed")

    assert {:ok, completed} = Conversations.complete_thread(thread.user_id, thread.id)
    assert %DateTime{} = completed.completed_at

    closed = receive_signal("allbert.workspace.ephemeral.closed")
    assert closed.data.surface_id == surface.id
    assert closed.data.thread_id == thread.id
    assert closed.data.dismissed_by == :thread_closed

    assert {:ok, []} = Ephemeral.surfaces_for_thread(thread.id, thread.user_id)

    assert {:ok, [dismissed]} =
             Ephemeral.surfaces_for_thread(thread.id, thread.user_id, include_dismissed: true)

    assert dismissed.id == surface.id
    assert dismissed.dismissed_by == "thread_closed"

    assert {:ok, [read_only_tile]} = Canvas.tiles_for_thread(thread.id, thread.user_id)
    assert read_only_tile.id == tile.id
    assert read_only_tile.read_only == true
    assert read_only_tile.body["text"] == "keep this"

    assert {:error, :thread_completed} =
             Canvas.update_tile(tile.id, %{user_id: thread.user_id, body: %{text: "edit"}})

    assert {:error, :thread_completed} =
             thread
             |> Repo.reload!()
             |> Conversations.append_user_message("another turn")

    assert {:ok, next_thread} = Conversations.resolve_thread(%{user_id: thread.user_id})
    assert next_thread.id != thread.id
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp receive_signal(type) do
    receive do
      {:signal, %{type: ^type} = signal} -> signal
      {:signal, _signal} -> receive_signal(type)
    after
      1_000 -> flunk("expected signal #{type}")
    end
  end
end
