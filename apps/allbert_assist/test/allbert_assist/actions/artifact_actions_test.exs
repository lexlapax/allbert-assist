defmodule AllbertAssist.Actions.ArtifactActionsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @moduletag :home_fs_serial
  @moduletag :app_env_serial

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
        "allbert-artifact-actions-#{System.unique_integer([:positive])}"
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

    {:ok, home: home}
  end

  test "artifact actions are registered internal actions" do
    for action <- ~w[put_artifact get_artifact list_artifacts delete_artifact artifact_doctor] do
      assert {:ok, module} = Registry.resolve(action)
      assert module.name() == action
      assert {:ok, capability} = Registry.capability(action)
      assert capability.exposure == :internal
      assert capability.skill_backed? == false
    end

    assert {:ok, delete_capability} = Registry.capability("delete_artifact")
    assert delete_capability.confirmation == :required
    assert delete_capability.resumable?
  end

  test "put, get, and list artifacts through the runner without logging bytes" do
    enable_artifacts!()
    bytes = "secret-artifact-payload"

    put_response =
      capture_log([level: :info], fn ->
        assert {:ok, response} =
                 Runner.run(
                   "put_artifact",
                   %{bytes: bytes, metadata: %{mime: "text/plain", origin: "test"}},
                   context()
                 )

        send(self(), {:put_response, response})
      end)

    assert_received {:put_response, response}
    refute put_response =~ bytes
    assert response.status == :completed
    assert response.permission_decision.permission == :artifact_write
    assert response.artifact.artifact_uri == Artifacts.artifact_uri(response.artifact.sha256)
    assert response.artifact.metadata.mime == "text/plain"
    assert response.artifact.metadata.retention == "retained"
    assert response.artifact.metadata.lifecycle == "active"

    sha256 = response.artifact.sha256

    assert {:ok, read} =
             Runner.run("get_artifact", %{sha256: sha256, include_bytes: true}, context())

    assert read.status == :completed
    assert read.artifact.bytes == bytes
    assert read.artifact.metadata.sha256 == sha256

    assert {:ok, listed} = Runner.run("list_artifacts", %{origin: "test"}, context())
    assert listed.status == :completed
    assert listed.count == 1
    assert [%{sha256: ^sha256}] = listed.artifacts

    assert {:ok, doctor} = Runner.run("artifact_doctor", %{}, context())
    assert doctor.status == :completed
    assert doctor.doctor.root_exists?
    assert doctor.doctor.gc_last_check.orphan_count == 0
  end

  test "put_artifact is disabled until artifacts and retention are enabled" do
    assert {:ok, disabled} =
             Runner.run(
               "put_artifact",
               %{bytes: "not stored", metadata: %{mime: "text/plain"}},
               context()
             )

    assert disabled.status == :denied
    assert disabled.error == :artifacts_disabled

    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})

    assert {:ok, retention_disabled} =
             Runner.run(
               "put_artifact",
               %{bytes: "not stored", metadata: %{mime: "text/plain"}},
               context()
             )

    assert retention_disabled.status == :denied
    assert retention_disabled.error == :artifact_retention_disabled
  end

  test "delete_artifact requires confirmation and approved resume deletes object and sidecar" do
    enable_artifacts!()

    assert {:ok, put} =
             Runner.run(
               "put_artifact",
               %{bytes: "delete me", metadata: %{mime: "text/plain"}},
               context()
             )

    sha256 = put.artifact.sha256
    assert Store.exists?(sha256)
    assert {:ok, _metadata} = MetadataIndex.lookup(sha256)

    assert {:ok, pending} = Runner.run("delete_artifact", %{sha256: sha256}, context())
    assert pending.status == :needs_confirmation
    assert pending.confirmation_id
    assert Store.exists?(sha256)
    assert {:ok, _metadata} = MetadataIndex.lookup(sha256)

    approved_context = Map.put(context(), :confirmation, %{approved?: true})
    assert {:ok, deleted} = Runner.run("delete_artifact", %{sha256: sha256}, approved_context)

    assert deleted.status == :completed
    assert deleted.artifact.sha256 == sha256
    refute Store.exists?(sha256)
    assert {:error, :not_found} = MetadataIndex.lookup(sha256)
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
      channel: :test,
      request: %{
        operator_id: "local",
        user_id: "local",
        input_signal_id: "sig-artifacts"
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
