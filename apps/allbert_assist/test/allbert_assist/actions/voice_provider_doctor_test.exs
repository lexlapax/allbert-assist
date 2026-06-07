defmodule AllbertAssist.Actions.VoiceProviderDoctorTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Settings.DoctorVoiceProvider
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  setup {Req.Test, :verify_on_exit!}

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-voice-doctor-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    :ok
  end

  test "fake STT profile returns the ADR 0047 voice doctor fields" do
    assert {:ok, response} =
             DoctorVoiceProvider.run(%{profile: "voice_stt_fake"}, doctor_context())

    assert response.status == :completed
    assert response.provider == "fake_voice"
    assert response.doctor.endpoint_kind == :local_endpoint
    assert response.doctor.credential_ok == nil
    assert response.doctor.endpoint_ok == true
    assert response.doctor.model_available == true
    assert response.doctor.redacted_host == "fixture"
    assert response.doctor.provider_capabilities == ["speech_to_text"]
    assert response.doctor.provider_deployment_mode == :fake
    assert response.doctor.speech_to_text_supported == true
    assert response.doctor.text_to_speech_supported == false
    assert response.doctor.audio_formats_supported == ["wav", "mp3", "m4a", "ogg", "webm"]
    assert response.doctor.audio_sample_rates_supported == [16_000, 44_100, 48_000]
    assert response.doctor.provider_usage_metadata_available == false
    assert response.doctor.fixture_probe_ok == true
    assert response.doctor.transcode_available == true
    assert response.diagnostics == []

    refute inspect(response) =~ "http://"
    refute inspect(response) =~ "https://"
    refute inspect(response) =~ "/v1"
    refute inspect(response) =~ "sk-"
    refute inspect(response) =~ ".wav"
  end

  test "fake TTS profile reports synthesis support only" do
    assert {:ok, response} =
             DoctorVoiceProvider.run(%{profile: "voice_tts_fake"}, doctor_context())

    assert response.status == :completed
    assert response.doctor.provider_capabilities == ["text_to_speech"]
    assert response.doctor.speech_to_text_supported == false
    assert response.doctor.text_to_speech_supported == true
    assert response.doctor.audio_formats_supported == ["wav", "mp3"]
    assert response.doctor.fixture_probe_ok == true
  end

  test "text-only profile returns a stable voice capability diagnostic" do
    assert {:ok, response} = DoctorVoiceProvider.run(%{profile: "local"}, doctor_context())

    assert response.status == :completed
    assert response.doctor.endpoint_kind == :local_endpoint
    assert response.doctor.model_available == false
    assert response.doctor.provider_capabilities == []
    assert response.doctor.speech_to_text_supported == false
    assert response.doctor.text_to_speech_supported == false
    assert [%{code: :voice_capability_missing}] = response.doctor.diagnostics
    assert response.doctor.redacted_host == "localhost"

    refute inspect(response) =~ "localhost:11434/v1"
  end

  test "local endpoint doctor probes executable voice endpoint without leaking URL details" do
    Req.Test.stub(__MODULE__, fn
      %{request_path: "/v1/models"} = conn ->
        json(conn, %{"data" => [%{"id" => "whisper-local"}]})
    end)

    assert {:ok, response} =
             DoctorVoiceProvider.run(%{profile: "voice_stt_local"}, doctor_context())

    assert response.status == :completed
    assert response.provider == "local_voice"
    assert response.doctor.endpoint_ok == true
    assert response.doctor.model_available == true
    assert response.doctor.redacted_host == "127.0.0.1"
    assert response.doctor.provider_deployment_mode == :local_endpoint
    assert response.doctor.transcode_available == true
    assert response.doctor.diagnostics == []
    refute inspect(response) =~ "127.0.0.1:5050/v1"
  end

  test "voice doctor reports non-native Anthropic STT/TTS as a stable diagnostic" do
    install_anthropic_voice_profile!()

    assert {:ok, response} =
             DoctorVoiceProvider.run(%{profile: "voice_stt_anthropic"}, doctor_context())

    assert response.status == :completed
    assert response.provider == "anthropic"
    assert response.doctor.endpoint_ok == false
    assert response.doctor.model_available == false
    assert response.doctor.provider_deployment_mode == :remote_credentialed
    assert [%{code: :voice_capability_not_native}] = response.doctor.diagnostics
  end

  test "voice doctor reports denied local endpoint hosts through the ADR 0047 catalog" do
    assert {:ok, _setting} =
             Settings.put("providers.local_voice.base_url", "http://192.168.1.10:5050/v1", %{
               audit?: false
             })

    assert {:ok, response} =
             DoctorVoiceProvider.run(%{profile: "voice_stt_local"}, doctor_context())

    assert response.status == :completed
    assert response.doctor.endpoint_ok == false
    assert response.doctor.model_available == :unknown
    assert [%{code: :provider_host_denied}] = response.doctor.diagnostics
  end

  test "voice doctor reports unavailable transcode executable" do
    assert {:ok, response} =
             DoctorVoiceProvider.run(%{profile: "voice_stt_fake"}, %{
               voice_transcode_executable: "allbert-missing-ffmpeg-for-test"
             })

    assert response.status == :completed
    assert response.doctor.transcode_available == false
    assert Enum.any?(response.doctor.diagnostics, &(&1.code == :voice_transcode_unavailable))
  end

  test "voice doctor no longer defaults missing profile to fake provider" do
    assert {:ok, response} = DoctorVoiceProvider.run(%{}, doctor_context())

    assert response.status == :error
    refute inspect(response) =~ "voice_stt_fake"
  end

  defp doctor_context do
    %{
      voice_transcode_executable: "sh",
      voice_adapter_opts: [req_options: [plug: {Req.Test, __MODULE__}]]
    }
  end

  defp install_anthropic_voice_profile! do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/anthropic/api_key", "sk-ant-test", %{
               audit?: false
             })

    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "providers" => %{
                 "anthropic" => %{"enabled" => true}
               },
               "model_profiles" => %{
                 "voice_stt_anthropic" => %{
                   "provider" => "anthropic",
                   "model" => "claude-sonnet-4-20250514",
                   "capabilities" => ["speech_to_text"],
                   "media" => %{
                     "input_modalities" => ["audio"],
                     "output_modalities" => ["text"],
                     "transport_modes" => ["request_file"],
                     "deployment_mode" => "remote_credentialed",
                     "audio_formats_supported" => ["wav"],
                     "max_audio_bytes" => 10_485_760,
                     "max_audio_duration_ms" => 300_000
                   }
                 }
               }
             })
  end

  defp json(conn, body, status \\ 200) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
