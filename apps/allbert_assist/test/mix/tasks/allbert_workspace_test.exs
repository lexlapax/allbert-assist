defmodule Mix.Tasks.Allbert.WorkspaceTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Ephemeral
  alias AllbertAssist.Workspace.Fragment.SigningSecret
  alias Jido.Signal.Bus
  alias Mix.Tasks.Allbert.Workspace, as: WorkspaceTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-workspace-task-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.workspace")
      File.rm_rf!(home)
    end)

    {:ok, home: home}
  end

  test "rotates the workspace fragment signing secret", %{home: home} do
    output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["rotate-signing-secret"])
      end)

    assert output =~ "Rotated workspace fragment signing secret."
    assert output =~ "Fingerprint:"
    assert output =~ "Previous secret accepted until:"
    assert output =~ "Overlap seconds: 60"
    assert output =~ Path.join([home, "workspace", "secrets", "signing_secret"])

    {:ok, secret} = SigningSecret.read()
    assert SigningSecret.valid?(secret)
    refute output =~ secret
  end

  test "inspects the resolved workspace surface tree" do
    assert {:ok, _setting} = Settings.put("workspace.theme.mode", "dark", %{audit?: false})

    output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["inspect", "--user", "local", "--thread", "thread-1"])
      end)

    assert output =~ "Resolved workspace Surface tree"
    assert output =~ "Surface: :workspace /workspace kind=workspace"
    assert output =~ "workspace.theme.mode=dark"
    assert output =~ "user_id=local thread_id=thread-1"
    assert output =~ "- workspace-root workspace_shell"
    assert output =~ "  - workspace-canvas-region canvas"
    assert output =~ "    - workspace-empty-canvas empty_state"

    refute output =~ "settings_panel"
  end

  test "canvas CLI lists shows pins restores and purges tiles" do
    thread_id = "cli-thread"
    user_id = "alice"

    assert {:ok, tile} =
             Workspace.add_tile(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :text,
               body: %{text: "cli tile", api_key: "secret-value"}
             })

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.tile.**")

    drain_signals()

    list_output =
      capture_io(fn ->
        assert :ok =
                 WorkspaceTask.run([
                   "canvas",
                   "list",
                   "--user",
                   user_id,
                   "--thread",
                   thread_id
                 ])
      end)

    assert list_output =~ tile.id
    assert list_output =~ "deleted=false"
    assert list_output =~ "read_only=false"

    show_output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["canvas", "show", tile.id, "--user", user_id])
      end)

    assert show_output =~ "Tile: #{tile.id}"
    assert show_output =~ "cli tile"
    assert show_output =~ "[REDACTED]"
    refute show_output =~ "secret-value"

    pin_output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["canvas", "pin", tile.id, "--user", user_id])
      end)

    assert pin_output =~ "Pinned canvas tile: #{tile.id}"
    assert receive_signal("allbert.workspace.tile.updated").data.tile_id == tile.id
    assert {:ok, pinned} = Canvas.get_tile(tile.id, user_id)
    assert pinned.pinned == true

    unpin_output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["canvas", "unpin", tile.id, "--user", user_id])
      end)

    assert unpin_output =~ "Unpinned canvas tile: #{tile.id}"
    assert receive_signal("allbert.workspace.tile.updated").data.tile_id == tile.id

    assert :ok = Workspace.remove_tile(tile.id, user_id)
    assert receive_signal("allbert.workspace.tile.removed").data.tile_id == tile.id

    deleted_list_output =
      capture_io(fn ->
        assert :ok =
                 WorkspaceTask.run([
                   "canvas",
                   "list",
                   "--user",
                   user_id,
                   "--thread",
                   thread_id,
                   "--include-deleted"
                 ])
      end)

    assert deleted_list_output =~ tile.id
    assert deleted_list_output =~ "deleted=true"

    deleted_show_output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["canvas", "show", tile.id, "--user", user_id])
      end)

    assert deleted_show_output =~ "Deleted: true"

    restore_output =
      capture_io(fn ->
        assert :ok = WorkspaceTask.run(["canvas", "restore", tile.id, "--user", user_id])
      end)

    assert restore_output =~ "Restored canvas tile: #{tile.id}"
    assert receive_signal("allbert.workspace.tile.added").data.tile_id == tile.id

    assert :ok = Workspace.remove_tile(tile.id, user_id)
    assert receive_signal("allbert.workspace.tile.removed").data.tile_id == tile.id

    purge_output =
      capture_io(fn ->
        assert :ok =
                 WorkspaceTask.run([
                   "canvas",
                   "purge",
                   "--user",
                   user_id,
                   "--before",
                   "2999-01-01"
                 ])
      end)

    assert purge_output =~ "Purged canvas tiles before 2999-01-01T00:00:00Z: 1"
    assert purge_output =~ tile.id
    assert receive_signal("allbert.workspace.tile.removed").data.tile_id == tile.id
    assert {:error, :not_found} = Canvas.get_tile(tile.id, user_id, include_deleted: true)
  end

  test "ephemeral CLI lists active and dismissed surfaces" do
    thread_id = "cli-ephemeral-thread"
    user_id = "alice"

    assert {:ok, active} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :approval_card,
               body: %{title: "active"}
             })

    assert {:ok, dismissed} =
             Ephemeral.open(%{
               thread_id: thread_id,
               user_id: user_id,
               kind: :trace_viewer,
               body: %{title: "dismissed"}
             })

    assert {:ok, _dismissed} = Ephemeral.dismiss(dismissed.id, user_id, :operator)

    list_output =
      capture_io(fn ->
        assert :ok =
                 WorkspaceTask.run([
                   "ephemeral",
                   "list",
                   "--user",
                   user_id,
                   "--thread",
                   thread_id
                 ])
      end)

    assert list_output =~ active.id
    refute list_output =~ dismissed.id

    include_output =
      capture_io(fn ->
        assert :ok =
                 WorkspaceTask.run([
                   "ephemeral",
                   "list",
                   "--user",
                   user_id,
                   "--thread",
                   thread_id,
                   "--include-dismissed"
                 ])
      end)

    assert include_output =~ active.id
    assert include_output =~ dismissed.id
    assert include_output =~ "dismissed_by=operator"
  end

  test "unknown commands raise usage" do
    assert_raise Mix.Error, ~r/allbert.workspace inspect/, fn ->
      WorkspaceTask.run(["unknown"])
    end
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

  defp drain_signals do
    receive do
      {:signal, _signal} -> drain_signals()
    after
      0 -> :ok
    end
  end
end
