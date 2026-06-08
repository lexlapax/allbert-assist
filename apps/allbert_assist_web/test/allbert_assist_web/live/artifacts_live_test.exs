defmodule AllbertAssistWeb.ArtifactsLiveTest do
  use AllbertAssistWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

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
        "allbert-artifacts-live-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    MetadataIndex.reset_cache!()
    Paths.ensure_home!()
    enable_artifacts!()

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

  test "route table exposes one host-owned artifact detail LiveView route" do
    routes = Phoenix.Router.routes(AllbertAssistWeb.Router)

    assert [
             %{
               path: "/apps/artifacts/:sha",
               plug: Phoenix.LiveView.Plug,
               plug_opts: :show,
               metadata: %{
                 phoenix_live_view: {AllbertArtifactsWeb.ArtifactLive, :show, _opts, _extra}
               }
             }
           ] = Enum.filter(routes, &(&1.path == "/apps/artifacts/:sha"))
  end

  test "detail page renders metadata and provenance without raw bytes", %{
    conn: conn,
    context: context
  } do
    {:ok, put} = seed_artifact!("artifact-live-secret-bytes", context)
    sha = put.artifact.sha256

    {:ok, _view, html} = live(conn, ~p"/apps/artifacts/#{sha}")

    assert html =~ "Artifact #{String.slice(sha, 0, 12)}"
    assert html =~ "mime=text/plain"
    assert html =~ "origin=live_test"
    assert html =~ "redaction=metadata_only"
    assert html =~ "thread=thread-artifacts-live"
    refute html =~ "artifact-live-secret-bytes"
  end

  test "invalid sha renders before action reads", %{conn: conn} do
    assert {:ok, _view, html} = live(conn, ~p"/apps/artifacts/INVALID")

    assert html =~ "Invalid artifact SHA"
    refute html =~ "permission_denied"
    refute html =~ "Artifact read failed"
  end

  test "missing artifact renders a redacted unavailable state", %{conn: conn} do
    missing_sha = String.duplicate("a", 64)

    assert {:ok, _view, html} = live(conn, ~p"/apps/artifacts/#{missing_sha}")

    assert html =~ "Artifact unavailable"
    assert html =~ "Artifact read failed"
    refute html =~ System.tmp_dir!()
  end

  test "delete button routes through core confirmation-gated action", %{
    conn: conn,
    context: context
  } do
    {:ok, put} = seed_artifact!("delete-confirmation-live", context)
    sha = put.artifact.sha256

    {:ok, view, _html} = live(conn, ~p"/apps/artifacts/#{sha}")

    html =
      view
      |> element("#artifact-delete-request")
      |> render_click()

    assert html =~ "Delete requires confirmation"
    assert Store.exists?(sha)
  end

  defp seed_artifact!(bytes, context) do
    Runner.run(
      "put_artifact",
      %{bytes: bytes, metadata: %{mime: "text/plain", origin: "live_test"}},
      context
    )
  end

  defp enable_artifacts! do
    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("artifacts.retention_enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_read", "allowed", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_write", "allowed", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_delete", "needs_confirmation", %{audit?: false})
  end

  defp context do
    %{
      user_id: "local",
      channel: :test,
      request: %{
        user_id: "local",
        operator_id: "local",
        thread_id: "thread-artifacts-live",
        input_signal_id: "sig-artifacts-live",
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
