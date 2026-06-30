defmodule AllbertAssist.Workspace.OfflineTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Workspace
  alias AllbertAssist.Workspace.Canvas
  alias AllbertAssist.Workspace.Canvas.Revision
  alias AllbertAssist.Workspace.Offline
  alias Jido.Signal.Bus

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(System.tmp_dir!(), "allbert-offline-test-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf(home)
    end)

    :ok
  end

  test "records browser update blobs, snapshot YAML, tile body, and signals" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-offline", "user-offline", "first"))

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.**")

    assert {:ok, result} =
             Offline.record_client_update(%{
               tile_id: tile.id,
               user_id: tile.user_id,
               thread_id: tile.thread_id,
               update: Base.encode64("opaque-yjs-update"),
               state_vector: Base.encode64("opaque-state-vector"),
               snapshot: "browser snapshot",
               origin: "browser"
             })

    assert result.conflict? == false
    assert result.conflict_count == 0
    assert result.revision.yjs_update == "opaque-yjs-update"
    assert result.revision.state_vector == "opaque-state-vector"
    assert result.revision.text_snapshot == "browser snapshot"
    assert result.revision.snapshot_yaml_path =~ ".revision."
    assert result.tile.current_revision_id == result.revision.id
    assert result.tile.body["text"] == "browser snapshot"

    assert {:ok, loaded} = Workspace.get_tile(tile.id, tile.user_id)
    assert loaded.current_revision_id == result.revision.id
    assert loaded.body["text"] == "browser snapshot"

    assert {:ok, "browser snapshot"} = Offline.latest_snapshot(tile.id, tile.user_id)

    reconciled = receive_signal("allbert.workspace.offline.reconciled")
    assert reconciled.data.tile_id == tile.id
    assert reconciled.data.revision_id == result.revision.id
    assert reconciled.data.conflict_count == 0

    updated = receive_signal("allbert.workspace.tile.updated")
    assert updated.data.metadata.revision_id == result.revision.id
    assert updated.data.metadata.changed_fields == [:body, :current_revision_id, :metadata]
  end

  test "detects stale base revisions and exposes pending conflict summary" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-conflict", "user-conflict", "base"))

    assert {:ok, first} =
             Offline.record_client_update(%{
               tile_id: tile.id,
               user_id: tile.user_id,
               thread_id: tile.thread_id,
               snapshot: "first edit",
               origin: "browser"
             })

    assert first.conflict? == false

    assert {:ok, second} =
             Offline.record_client_update(%{
               tile_id: tile.id,
               user_id: tile.user_id,
               thread_id: tile.thread_id,
               base_revision_id: nil,
               snapshot: "second stale edit",
               origin: "offline_reconnect"
             })

    assert second.conflict? == true
    assert second.conflict_count == 1

    assert {:ok, summary} = Offline.pending_conflict_summary(tile.id, tile.user_id)
    assert summary.conflict? == true
    assert summary.conflict_count == 1
    assert summary.latest_revision_id == second.revision.id
    assert summary.revert_revision_id == first.revision.id
  end

  test "rejects oversize payloads before writing a revision" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-limit", "user-limit", "base"))

    assert {:error, :payload_too_large} =
             Offline.record_client_update(%{
               tile_id: tile.id,
               user_id: tile.user_id,
               thread_id: tile.thread_id,
               update: Base.encode64("12345"),
               state_vector: Base.encode64("12345"),
               snapshot: "12345",
               max_bytes: 4
             })

    assert Repo.aggregate(Revision, :count, :id) == 0
  end

  test "rejects offline snapshots that exceed the canvas tile body limit" do
    assert {:ok, _setting} =
             Settings.put("workspace.canvas.tile_body_max_bytes", 1024, %{audit?: false})

    assert {:ok, tile} =
             Canvas.add_tile(tile_attrs("thread-body-limit", "user-body-limit", "base"))

    assert {:error, :tile_body_too_large} =
             Offline.record_client_update(%{
               tile_id: tile.id,
               user_id: tile.user_id,
               thread_id: tile.thread_id,
               snapshot: String.duplicate("x", 2_000),
               max_bytes: 16_384
             })

    assert Repo.aggregate(Revision, :count, :id) == 0
    assert {:ok, "base"} = Offline.latest_snapshot(tile.id, tile.user_id)
  end

  test "registered offline update action respects workspace write denial" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-denied", "user-denied", "base"))

    assert {:ok, _setting} =
             Settings.put("permissions.workspace_canvas_write", "denied", %{audit?: false})

    assert {:ok, response} =
             Runner.run(
               "record_workspace_offline_update",
               %{
                 tile_id: tile.id,
                 user_id: tile.user_id,
                 thread_id: tile.thread_id,
                 snapshot: "denied edit"
               },
               %{actor: tile.user_id, user_id: tile.user_id, channel: :test}
             )

    assert response.status == :denied
    assert response.reason == :permission_denied
    assert response.runner_metadata.permission_decision.permission == :workspace_canvas_write
    assert response.runner_metadata.permission_decision.decision == :denied
    assert Repo.aggregate(Revision, :count, :id) == 0
  end

  test "registered offline update action records a revision and broadcasts normally" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-action", "user-action", "base"))

    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, "allbert.workspace.**")

    assert {:ok, response} =
             Runner.run(
               "record_workspace_offline_update",
               %{
                 tile_id: tile.id,
                 user_id: tile.user_id,
                 thread_id: tile.thread_id,
                 update: Base.encode64("opaque-yjs-update"),
                 state_vector: Base.encode64("opaque-state-vector"),
                 snapshot: "action snapshot",
                 origin: "browser"
               },
               %{actor: tile.user_id, user_id: tile.user_id, channel: :test}
             )

    assert response.status == :completed
    assert response.result.revision.text_snapshot == "action snapshot"
    assert response.actions |> List.first() |> Map.fetch!(:permission) == :workspace_canvas_write
    assert response.runner_metadata.action_name == "record_workspace_offline_update"

    reconciled = receive_signal("allbert.workspace.offline.reconciled")
    assert reconciled.data.tile_id == tile.id
    assert reconciled.data.revision_id == response.result.revision.id

    updated = receive_signal("allbert.workspace.tile.updated")
    assert updated.data.metadata.revision_id == response.result.revision.id
  end

  test "registered revert action restores a prior snapshot through the action boundary" do
    assert {:ok, tile} = Canvas.add_tile(tile_attrs("thread-revert", "user-revert", "base"))

    assert {:ok, first} =
             Offline.record_client_update(%{
               tile_id: tile.id,
               user_id: tile.user_id,
               thread_id: tile.thread_id,
               snapshot: "first edit"
             })

    assert {:ok, _second} =
             Offline.record_client_update(%{
               tile_id: tile.id,
               user_id: tile.user_id,
               thread_id: tile.thread_id,
               base_revision_id: first.revision.id,
               snapshot: "second edit"
             })

    assert {:ok, response} =
             Runner.run(
               "revert_tile_revision",
               %{tile_id: tile.id, revision_id: first.revision.id},
               %{actor: tile.user_id, user_id: tile.user_id, channel: :test}
             )

    assert response.status == :completed
    assert response.reverted_to_revision_id == first.revision.id

    assert {:ok, "first edit"} = Offline.latest_snapshot(tile.id, tile.user_id)
  end

  defp tile_attrs(thread_id, user_id, text) do
    %{thread_id: thread_id, user_id: user_id, kind: :text, body: %{text: text}}
  end

  defp receive_signal(type) do
    receive do
      {:signal, %{type: ^type} = signal} -> signal
      {:signal, _signal} -> receive_signal(type)
    after
      1_000 -> flunk("expected signal #{type}")
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
