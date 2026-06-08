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

  defp find_child(%Surface{nodes: [%Node{children: children}]}, component),
    do: Enum.find(children, &(&1.component == component))

  defp find_child(%Node{children: children}, component),
    do: Enum.find(children, &(&1.component == component))

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

  defp seed_context do
    %{
      user_id: "local",
      channel: :test,
      request: %{
        user_id: "local",
        operator_id: "local",
        thread_id: "thread-artifacts-seed",
        input_signal_id: "sig-artifacts-seed",
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
