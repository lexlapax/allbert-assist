defmodule Mix.Tasks.Allbert.ArtifactsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Artifacts, as: ArtifactsTask

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
        "allbert-artifacts-task-#{System.unique_integer([:positive])}"
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

    %{home: home, context: context()}
  end

  test "list and show render redacted artifact metadata only", %{context: context} do
    {:ok, put} = seed_artifact!("cli-secret-bytes", context)
    sha = put.artifact.sha256

    list_output = capture_io(fn -> ArtifactsTask.run(["list"]) end)

    assert list_output =~ String.slice(sha, 0, 12)
    assert list_output =~ "mime=text/plain"
    assert list_output =~ "origin=cli_test"
    refute list_output =~ "cli-secret-bytes"

    show_output = capture_io(fn -> ArtifactsTask.run(["show", sha]) end)

    assert show_output =~ "sha=#{sha}"
    assert show_output =~ "uri=artifact://sha256/#{sha}"
    assert show_output =~ "redaction=metadata_only"
    refute show_output =~ "cli-secret-bytes"
  end

  test "threads command prints provenance links without reading bytes", %{context: context} do
    {:ok, put} = seed_artifact!("thread-secret-bytes", context)
    sha = put.artifact.sha256

    output = capture_io(fn -> ArtifactsTask.run(["threads", sha]) end)

    assert output =~ "role=created_by"
    assert output =~ "thread=thread-artifacts-cli"
    assert output =~ "message=thread-level"
    refute output =~ "thread-secret-bytes"
  end

  test "rm command queues confirmation and does not delete without approval", %{context: context} do
    {:ok, put} = seed_artifact!("delete-cli-secret", context)
    sha = put.artifact.sha256

    output = capture_io(fn -> ArtifactsTask.run(["rm", sha]) end)

    assert output =~ "artifact delete needs confirmation:"
    assert output =~ String.slice(sha, 0, 12)
    assert Store.exists?(sha)
    refute output =~ "delete-cli-secret"
  end

  test "doctor command prints health without the raw artifact home", %{
    context: context,
    home: home
  } do
    {:ok, _put} = seed_artifact!("doctor-secret", context)

    output = capture_io(fn -> ArtifactsTask.run(["doctor"]) end)

    assert output =~ "artifact doctor:"
    assert output =~ "enabled=true"
    assert output =~ "root_exists=true"
    refute output =~ home
    refute output =~ "doctor-secret"
  end

  test "usage is printed for unknown arguments" do
    output = capture_io(fn -> ArtifactsTask.run([]) end)

    assert output =~ "mix allbert.artifacts list"
    assert output =~ "mix allbert.artifacts rm"
  end

  defp seed_artifact!(bytes, context) do
    Runner.run(
      "put_artifact",
      %{bytes: bytes, metadata: %{mime: "text/plain", origin: "cli_test"}},
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
      actor: "local",
      user_id: "local",
      channel: :test,
      request: %{
        operator_id: "local",
        user_id: "local",
        thread_id: "thread-artifacts-cli",
        input_signal_id: "sig-artifacts-cli",
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
