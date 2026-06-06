defmodule AllbertAssist.Actions.VoiceProviderDoctorTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Settings.DoctorVoiceProvider
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

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
    assert {:ok, response} = DoctorVoiceProvider.run(%{profile: "voice_stt_fake"}, %{})

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
    assert response.doctor.audio_sample_rates_supported == [16000, 44100, 48000]
    assert response.doctor.provider_usage_metadata_available == false
    assert response.doctor.fixture_probe_ok == true
    assert response.diagnostics == []

    refute inspect(response) =~ "http://"
    refute inspect(response) =~ "https://"
    refute inspect(response) =~ "/v1"
    refute inspect(response) =~ "sk-"
    refute inspect(response) =~ ".wav"
  end

  test "fake TTS profile reports synthesis support only" do
    assert {:ok, response} = DoctorVoiceProvider.run(%{profile: "voice_tts_fake"}, %{})

    assert response.status == :completed
    assert response.doctor.provider_capabilities == ["text_to_speech"]
    assert response.doctor.speech_to_text_supported == false
    assert response.doctor.text_to_speech_supported == true
    assert response.doctor.audio_formats_supported == ["wav", "mp3"]
    assert response.doctor.fixture_probe_ok == true
  end

  test "text-only profile returns a stable voice capability diagnostic" do
    assert {:ok, response} = DoctorVoiceProvider.run(%{profile: "local"}, %{})

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

  defp restore_env(env) do
    Enum.each(env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
