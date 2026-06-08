defmodule AllbertAssist.Security.V050ArtifactStoreEvalTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial
  @moduletag :home_fs_serial
  @moduletag :app_env_serial

  import ExUnit.CaptureLog

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Artifacts.ThreadLink
  alias AllbertAssist.Artifacts.MediaRetention
  alias AllbertAssist.Paths
  alias AllbertAssist.Repo
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings

  @eval_ids [
    "artifact-content-address-immutable-001",
    "artifact-bytes-trace-redaction-001",
    "artifact-identity-no-authority-001",
    "artifact-delete-confirmation-001",
    "artifact-retention-default-off-001",
    "artifact-ingest-bounds-001",
    "artifact-sensor-advisory-only-001",
    "artifact-thread-link-no-authority-001"
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
        "allbert-v050-artifact-eval-#{System.unique_integer([:positive])}"
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

    {:ok, home: home, context: context()}
  end

  test "v0.50 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v050)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :artifact_store))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "content addresses are immutable and artifact bytes stay out of traces", %{
    context: context,
    home: home
  } do
    assert_eval!("artifact-content-address-immutable-001")
    assert_eval!("artifact-bytes-trace-redaction-001")

    enable_artifacts!()
    bytes = "v050-secret-artifact-payload"

    log =
      capture_log(fn ->
        assert {:ok, put} =
                 Runner.run(
                   "put_artifact",
                   %{bytes: bytes, metadata: %{mime: "text/plain", origin: "v050_eval"}},
                   context
                 )

        send(self(), {:artifact_put, put})
      end)

    assert_received {:artifact_put, put}
    sha256 = Store.sha256(bytes)

    assert put.status == :completed
    assert put.artifact.sha256 == sha256
    assert put.artifact.artifact_uri == "artifact://sha256/#{sha256}"
    assert Store.exists?(sha256)

    assert {:ok, fields} = ResourceURI.derived_fields(put.artifact.artifact_uri)
    assert fields.origin_kind == :artifact_store
    assert fields.sha256 == sha256

    assert {:ok, duplicate} =
             Runner.run(
               "put_artifact",
               %{bytes: bytes, metadata: %{mime: "text/plain", origin: "v050_eval_duplicate"}},
               context
             )

    assert duplicate.artifact.sha256 == sha256
    assert duplicate.artifact.deduped? == true

    redacted =
      Redactor.redact_artifact_metadata(%{
        bytes: bytes,
        path: Path.join(home, "private/artifact.txt"),
        artifact_uri: put.artifact.artifact_uri,
        content_sha256: sha256
      })

    refute log =~ bytes
    refute inspect(redacted) =~ bytes
    refute inspect(redacted) =~ home
    assert redacted.artifact_uri == put.artifact.artifact_uri
    assert redacted.content_sha256 == sha256
  end

  test "artifact identity and thread links do not grant read authority", %{context: context} do
    assert_eval!("artifact-identity-no-authority-001")
    assert_eval!("artifact-thread-link-no-authority-001")

    enable_artifacts!()
    bytes = "thread-linked-artifact"

    assert {:ok, put} =
             Runner.run(
               "put_artifact",
               %{bytes: bytes, metadata: %{mime: "text/plain", origin: "thread_eval"}},
               context
             )

    assert {:ok, duplicate} =
             Runner.run(
               "put_artifact",
               %{bytes: bytes, metadata: %{mime: "text/plain", origin: "thread_eval"}},
               context
             )

    sha256 = put.artifact.sha256
    assert duplicate.artifact.sha256 == sha256

    assert [link] = Repo.all(ThreadLink)
    assert link.artifact_sha256 == sha256
    assert link.thread_id == "thread-v050-artifact-eval"

    assert {:ok, listed} =
             Runner.run("list_artifacts", %{thread_id: link.thread_id}, context)

    assert [%{sha256: ^sha256}] = listed.artifacts

    assert {:ok, reverse} = Runner.run("artifact_threads", %{sha256: sha256}, context)
    assert [%{thread_id: "thread-v050-artifact-eval"}] = reverse.links

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_read", "denied", %{audit?: false})

    assert {:ok, denied_get} =
             Runner.run("get_artifact", %{artifact_uri: put.artifact.artifact_uri}, context)

    assert denied_get.status == :denied
    assert denied_get.error == :permission_denied

    assert {:ok, denied_list} =
             Runner.run("list_artifacts", %{thread_id: link.thread_id}, context)

    assert denied_list.status == :denied
    assert denied_list.error == :permission_denied
  end

  test "delete confirmation and retention default-off are enforced", %{context: context} do
    assert_eval!("artifact-delete-confirmation-001")
    assert_eval!("artifact-retention-default-off-001")

    assert {:ok, _setting} = Settings.put("artifacts.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_write", "allowed", %{audit?: false})

    default_off_bytes = "retention-default-off"

    assert {:ok, default_off} =
             Runner.run(
               "put_artifact",
               %{bytes: default_off_bytes, metadata: %{mime: "text/plain"}},
               context
             )

    assert default_off.status == :denied
    assert default_off.error == :artifact_retention_disabled
    refute Store.exists?(Store.sha256(default_off_bytes))

    enable_artifacts!()

    assert {:ok, put} =
             Runner.run(
               "put_artifact",
               %{bytes: "delete-confirmation-artifact", metadata: %{mime: "text/plain"}},
               context
             )

    sha256 = put.artifact.sha256
    assert Store.exists?(sha256)

    assert {:ok, pending} = Runner.run("delete_artifact", %{sha256: sha256}, context)
    assert pending.status == :needs_confirmation
    assert pending.confirmation_id
    assert Store.exists?(sha256)
    assert {:ok, _metadata} = MetadataIndex.lookup(sha256)

    approved_context = Map.put(context, :confirmation, %{approved?: true})
    assert {:ok, deleted} = Runner.run("delete_artifact", %{sha256: sha256}, approved_context)
    assert deleted.status == :completed
    refute Store.exists?(sha256)
    assert {:error, :not_found} = MetadataIndex.lookup(sha256)
  end

  test "ingest bounds and sensor authority are enforced", %{context: context} do
    assert_eval!("artifact-ingest-bounds-001")
    assert_eval!("artifact-sensor-advisory-only-001")

    enable_artifacts!()

    assert {:ok, _setting} = Settings.put("artifacts.max_bytes", 4, %{audit?: false})

    assert {:ok, oversized} =
             Runner.run(
               "put_artifact",
               %{bytes: "12345", metadata: %{mime: "text/plain"}},
               context
             )

    assert oversized.status == :error
    assert oversized.error == {:artifact_too_large, 5, 4}
    refute Store.exists?(Store.sha256("12345"))

    assert {:ok, _setting} = Settings.put("artifacts.max_bytes", 128, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("artifacts.allowed_mime", ["image/png"], %{audit?: false})

    assert {:ok, disallowed} =
             Runner.run(
               "put_artifact",
               %{bytes: "text fixture", metadata: %{mime: "text/plain"}},
               context
             )

    assert disallowed.status == :error
    assert disallowed.error == {:artifact_mime_not_allowed, "text/plain", ["image/png"]}
    refute Store.exists?(Store.sha256("text fixture"))

    assert {:ok, _setting} = Settings.put("artifacts.allowed_mime", ["*/*"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("permissions.artifact_write", "denied", %{audit?: false})

    sensor_bytes = "sensor-permission-denied"

    assert {:error, :permission_denied} =
             MediaRetention.put(
               :generated_image,
               sensor_bytes,
               %{filename: "image.png", mime: "image/png"},
               context: context
             )

    refute Store.exists?(Store.sha256(sensor_bytes))
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

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
      actor: "operator-v050-artifact-eval",
      user_id: "operator-v050-artifact-eval",
      channel: :test,
      surface: "v050_eval",
      request: %{
        operator_id: "operator-v050-artifact-eval",
        user_id: "operator-v050-artifact-eval",
        thread_id: "thread-v050-artifact-eval",
        input_signal_id: "signal-v050-artifact-eval",
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
