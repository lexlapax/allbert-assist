defmodule AllbertAssist.Artifacts.IngestionSensorTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Artifacts.IngestionConsumer
  alias AllbertAssist.Artifacts.IngestionSensor
  alias AllbertAssist.Artifacts.IngestionSupervisor
  alias AllbertAssist.Artifacts.MediaRetention
  alias AllbertAssist.Artifacts.MetadataIndex
  alias AllbertAssist.Artifacts.Store
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Jido.Signal.Bus

  @env_vars ["ALLBERT_HOME", "ALLBERT_HOME_DIR", "ALLBERT_SETTINGS_ROOT"]

  defmodule SlowIngestionServer do
    use GenServer

    def start_link(opts), do: GenServer.start_link(__MODULE__, :ok, opts)

    @impl true
    def init(:ok), do: {:ok, nil}

    @impl true
    def handle_call(_request, _from, state), do: {:noreply, state}
  end

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
        "allbert-artifact-ingestion-sensor-#{System.unique_integer([:positive])}"
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

    {:ok, home: home}
  end

  test "supervised Jido sensor runtime has an explicit dispatch target" do
    assert is_pid(Process.whereis(IngestionConsumer))
    assert sensor_pid = IngestionSupervisor.sensor_pid()
    assert Process.alive?(sensor_pid)

    runtime_state = :sys.get_state(sensor_pid)
    assert runtime_state.sensor == IngestionSensor
    assert runtime_state.context.agent_ref == IngestionConsumer
  end

  test "retained media emits a redacted ingestion signal and stores through put_artifact" do
    assert {:ok, _subscription_id} =
             Bus.subscribe(AllbertAssist.SignalBus, IngestionSensor.ingest_requested_type())

    bytes = "sensor-retained-secret-payload"

    assert {:ok, artifact} =
             MediaRetention.put(
               :voice_audio,
               bytes,
               %{
                 filename: "sensor.wav",
                 path: "/tmp/allbert/raw/sensor.wav",
                 source_resource_uri: "mic://capture/sensor",
                 capture_id: "cap_sensor"
               },
               context: context()
             )

    signal = receive_ingestion_signal()

    assert signal.type == IngestionSensor.ingest_requested_type()
    assert signal.source == IngestionSensor.source()
    assert signal.data.byte_size == byte_size(bytes)
    assert signal.data.content_sha256 == Store.sha256(bytes)
    assert signal.data.advisory_only? == true
    assert signal.data.metadata.origin == "retained_voice_audio"

    redacted_payload = inspect(signal.data)
    refute redacted_payload =~ bytes
    refute redacted_payload =~ "/tmp/allbert/raw"
    refute redacted_payload =~ "sensor.wav"

    assert Store.exists?(artifact.sha256)
    assert artifact.path == Store.object_path!(artifact.sha256)
    assert artifact.ingestion.action_name == "put_artifact"
    assert artifact.ingestion.signal_type == IngestionSensor.ingest_requested_type()
    assert artifact.ingestion.permission_decision.permission == :artifact_write
    assert artifact.ingestion.runner_metadata.action_name == "put_artifact"
  end

  test "disabling artifacts.enabled disables ingestion" do
    assert {:ok, _setting} = Settings.put("artifacts.enabled", false, %{audit?: false})

    bytes = "disabled-retained-payload"

    assert {:error, :artifacts_disabled} =
             MediaRetention.put(
               :generated_image,
               bytes,
               %{filename: "image.png", mime: "image/png"},
               context: context()
             )

    refute Store.exists?(Store.sha256(bytes))
  end

  test "sensor dispatch does not grant artifact_write authority" do
    assert {:ok, _setting} =
             Settings.put("permissions.artifact_write", "denied", %{audit?: false})

    bytes = "permission-denied-retained-payload"

    assert {:error, :permission_denied} =
             MediaRetention.put(
               :vision_media,
               bytes,
               %{
                 filename: "frame.png",
                 mime: "image/png",
                 source_resource_uri: "image://capture/frame"
               },
               context: context()
             )

    refute Store.exists?(Store.sha256(bytes))
  end

  test "ingestion consumer call timeout comes from Settings Central" do
    assert {:ok, _setting} =
             Settings.put("artifacts.ingestion_timeout_ms", 1_000, %{audit?: false})

    assert {:ok, server} =
             SlowIngestionServer.start_link(
               name: :"slow_ingestion_#{System.unique_integer([:positive])}"
             )

    assert catch_exit(
             IngestionConsumer.ingest("slow-payload", %{filename: "slow.txt"},
               server: server,
               context: context()
             )
           ) ==
             {:timeout,
              {GenServer, :call,
               [
                 server,
                 {:emit_ingest_request, "slow-payload", %{filename: "slow.txt"}, context()},
                 1_000
               ]}}
  end

  defp receive_ingestion_signal do
    receive do
      {:signal, signal} -> signal
    after
      1_000 -> flunk("expected artifact ingestion signal")
    end
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
        thread_id: "thr_sensor",
        input_signal_id: "sig-artifact-sensor"
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
