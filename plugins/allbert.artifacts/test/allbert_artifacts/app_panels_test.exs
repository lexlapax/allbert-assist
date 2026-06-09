defmodule AllbertArtifacts.AppPanelsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertArtifacts.App

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_artifacts_config = Application.get_env(:allbert_assist, AllbertAssist.Artifacts)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, AllbertAssist.Artifacts)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-artifacts-panel-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    MetadataIndex.reset_cache!()
    Paths.ensure_home!()

    on_exit(fn ->
      MetadataIndex.reset_cache!()
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(AllbertAssist.Artifacts, original_artifacts_config)
    end)

    %{context: context()}
  end

  test "static surfaces declare the workspace artifacts panel" do
    assert [surface] = App.surfaces()

    assert %Surface{
             id: :artifacts_browser_panel,
             app_id: :allbert_artifacts,
             path: "/workspace",
             kind: :panel,
             zone: :canvas_panels
           } = surface

    assert surface.metadata.visible_when == :operator_opened
    assert surface.metadata.zone == :canvas_panels
    assert {:ok, _surface} = Surface.validate_surface(surface)
    assert Surface.validate_surface_catalog(surface, App.surface_catalog()) == :ok
  end

  test "hydrated panel lists artifact metadata through core actions", %{context: context} do
    enable_artifacts!()

    assert {:ok, put} =
             Runner.run(
               "put_artifact",
               %{
                 bytes: "artifact-panel-secret-bytes",
                 metadata: %{mime: "text/plain", origin: "panel_test"}
               },
               seed_context()
             )

    assert [surface] = App.workspace_panel_surfaces(context)
    assert {:ok, _surface} = Surface.validate_surface(surface)
    assert Surface.validate_surface_catalog(surface, App.surface_catalog()) == :ok

    row = find_child(surface, :section)
    assert row.props.title =~ "text/plain"
    assert row.props.body =~ String.slice(put.artifact.sha256, 0, 12)
    assert row.props.body =~ "origin=panel_test"
    assert row.props.body =~ "redaction=metadata_only"
    refute inspect(surface) =~ "artifact-panel-secret-bytes"
    assert row.children == []
  end

  test "hydrated panel applies explicit filters without treating ambient thread as a filter", %{
    context: context
  } do
    enable_artifacts!()

    assert {:ok, target} =
             Runner.run(
               "put_artifact",
               %{
                 bytes: "artifact-panel-target-secret",
                 metadata: %{
                   mime: "text/plain",
                   origin: "panel_target",
                   created_at: "2026-06-08T00:00:00Z"
                 }
               },
               seed_context("thread-artifacts-target", "sig-artifacts-target")
             )

    assert {:ok, other} =
             Runner.run(
               "put_artifact",
               %{
                 bytes: "artifact-panel-other-secret",
                 metadata: %{
                   mime: "image/png",
                   origin: "panel_other",
                   created_at: "2026-01-01T00:00:00Z"
                 }
               },
               seed_context("thread-artifacts-other", "sig-artifacts-other")
             )

    assert [unfiltered] = App.workspace_panel_surfaces(context)
    unfiltered_text = inspect(unfiltered)
    assert unfiltered_text =~ String.slice(target.artifact.sha256, 0, 12)
    assert unfiltered_text =~ String.slice(other.artifact.sha256, 0, 12)

    filtered_context =
      Map.put(context, :artifacts_browser_filters, %{
        type: "text/plain",
        origin: "panel_target",
        thread: "thread-artifacts-target",
        since: "2026-06-01"
      })

    assert [filtered] = App.workspace_panel_surfaces(filtered_context)
    filter_node = find_child(filtered, "artifacts-browser-filters")
    row = find_child(filtered, :section, "artifact-row-0")

    assert filter_node.props.body =~ "origin=panel_target"
    assert filter_node.props.body =~ "thread=thread-artifacts-target"
    assert filter_node.props.body =~ "type=text/plain"
    assert row.props.body =~ String.slice(target.artifact.sha256, 0, 12)
    refute inspect(filtered) =~ String.slice(other.artifact.sha256, 0, 12)
    refute inspect(filtered) =~ "artifact-panel-target-secret"
    refute inspect(filtered) =~ "artifact-panel-other-secret"
  end

  test "panel renders a redacted unavailable state when core read action fails", %{
    context: context
  } do
    assert {:ok, _setting} =
             Settings.put("permissions.artifact_read", "denied", %{audit?: false})

    assert [surface] = App.workspace_panel_surfaces(context)
    assert {:ok, _surface} = Surface.validate_surface(surface)

    assert %Node{component: :empty_state, props: props} = find_child(surface, :empty_state)
    assert props.title == "Artifacts unavailable"
    assert props.body =~ "permission_denied"
  end

  defp find_child(%Surface{nodes: [%Node{children: children}]}, component)
       when is_atom(component),
       do: Enum.find(children, &(&1.component == component))

  defp find_child(%Node{children: children}, component) when is_atom(component),
    do: Enum.find(children, &(&1.component == component))

  defp find_child(%Surface{nodes: [%Node{children: children}]}, id) when is_binary(id),
    do: Enum.find(children, &(&1.id == id))

  defp find_child(%Surface{nodes: [%Node{children: children}]}, component, id),
    do: Enum.find(children, &(&1.component == component and &1.id == id))

  defp enable_artifacts! do
    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("artifacts.retention_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_read", "allowed", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_write", "allowed", %{audit?: false})
  end

  defp context do
    %{
      user_id: "local",
      channel: :workspace,
      request: %{
        user_id: "local",
        operator_id: "local",
        thread_id: "thread-artifacts-panel",
        input_signal_id: "sig-artifacts-panel",
        channel: :workspace
      }
    }
  end

  defp seed_context(thread_id \\ "thread-artifacts-seed", signal_id \\ "sig-artifacts-seed") do
    %{
      user_id: "local",
      channel: :test,
      request: %{
        user_id: "local",
        operator_id: "local",
        thread_id: thread_id,
        input_signal_id: signal_id,
        channel: :test
      }
    }
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
