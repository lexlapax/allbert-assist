defmodule AllbertAssist.Security.V050bArtifactsBrowserEvalTest do
  use AllbertAssist.DataCase, async: false, lane: :security_eval_serial

  import ExUnit.CaptureIO

  alias AllbertArtifacts.App
  alias AllbertArtifacts.Plugin
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Artifacts, as: ArtifactsTask

  @eval_ids [
    "artifacts-browser-read-only-via-action-001",
    "artifacts-browser-no-raw-bytes-rendered-001",
    "artifacts-browser-grants-no-authority-001",
    "artifacts-browser-delete-confirmation-001"
  ]

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
        "allbert-v050b-artifacts-browser-eval-#{System.unique_integer([:positive])}"
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

    {:ok, context: context(), home: home}
  end

  test "v0.50b eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v050b)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :artifact_browser))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "browser plugin remains data-only and read denial has no fallback", %{context: context} do
    assert_eval!("artifacts-browser-read-only-via-action-001")
    assert_eval!("artifacts-browser-grants-no-authority-001")

    assert Plugin.actions() == []
    assert Plugin.channels() == []
    assert Plugin.settings_schema() == []
    assert App.actions() == []
    assert App.memory_namespace() == nil

    enable_artifacts!()
    %{artifact: %{sha256: sha256}} = seed_artifact!("browser-action-boundary-secret", context)

    assert [allowed_panel] = App.workspace_panel_surfaces(context)
    assert inspect(allowed_panel) =~ String.slice(sha256, 0, 12)
    refute inspect(allowed_panel) =~ "browser-action-boundary-secret"

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_read", "denied", %{audit?: false})

    assert [denied_panel] = App.workspace_panel_surfaces(context)
    denied_panel_text = inspect(denied_panel)
    assert denied_panel_text =~ "Artifacts unavailable"
    assert denied_panel_text =~ "permission_denied"
    refute denied_panel_text =~ String.slice(sha256, 0, 12)
    refute denied_panel_text =~ "browser-action-boundary-secret"

    cli_error = capture_io(:stderr, fn -> ArtifactsTask.run(["show", sha256]) end)
    assert cli_error =~ "artifacts show failed"
    assert cli_error =~ "permission_denied"
    refute cli_error =~ "browser-action-boundary-secret"
  end

  test "panel and CLI render metadata only", %{context: context, home: home} do
    assert_eval!("artifacts-browser-no-raw-bytes-rendered-001")

    enable_artifacts!()
    raw_bytes = "browser-redaction-raw-secret-bytes"
    %{artifact: %{sha256: sha256}} = seed_artifact!(raw_bytes, context)

    assert [panel] = App.workspace_panel_surfaces(context)
    panel_text = inspect(panel)
    assert panel_text =~ "redaction=metadata_only"
    assert panel_text =~ String.slice(sha256, 0, 12)
    refute panel_text =~ raw_bytes
    refute panel_text =~ home

    list_output = capture_io(fn -> ArtifactsTask.run(["list"]) end)
    show_output = capture_io(fn -> ArtifactsTask.run(["show", sha256]) end)
    threads_output = capture_io(fn -> ArtifactsTask.run(["threads", sha256]) end)

    for output <- [list_output, show_output, threads_output] do
      refute output =~ raw_bytes
      refute output =~ home
    end

    assert list_output =~ String.slice(sha256, 0, 12)
    assert show_output =~ "sha=#{sha256}"
    assert show_output =~ "redaction=metadata_only"
    assert threads_output =~ "role=created_by"
  end

  test "delete routes through the core confirmation-gated action", %{context: context} do
    assert_eval!("artifacts-browser-delete-confirmation-001")

    enable_artifacts!()
    %{artifact: %{sha256: sha256}} = seed_artifact!("browser-delete-secret", context)

    output = capture_io(fn -> ArtifactsTask.run(["rm", sha256]) end)

    assert output =~ "artifact delete needs confirmation:"
    assert output =~ String.slice(sha256, 0, 12)
    assert Store.exists?(sha256)
    assert {:ok, _metadata} = MetadataIndex.lookup(sha256)
    refute output =~ "browser-delete-secret"
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

  defp seed_artifact!(bytes, context) do
    assert {:ok, %{status: :completed} = put} =
             Runner.run(
               "put_artifact",
               %{
                 bytes: bytes,
                 metadata: %{
                   mime: "text/plain",
                   origin: "v050b_eval",
                   created_at: "2026-06-09T00:00:00Z"
                 }
               },
               context
             )

    put
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
      actor: "local",
      user_id: "local",
      channel: :test,
      surface: "v050b_eval",
      request: %{
        operator_id: "local",
        user_id: "local",
        thread_id: "thread-v050b-artifacts-browser-eval",
        input_signal_id: "signal-v050b-artifacts-browser-eval",
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
