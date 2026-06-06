defmodule AllbertAssist.Actions.SynthesizeVoiceTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Voice.SynthesizeVoice
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
        "allbert-synthesize-voice-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    {:ok, home: home}
  end

  test "fake TTS provider writes bounded output and redacted usage metadata" do
    enable_voice!()
    use_fake_tts!()

    assert {:ok, response} = SynthesizeVoice.run(%{text: "Hello spoken world"}, context())

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed
    assert File.regular?(response.audio_file)
    assert {:ok, <<"RIFF", _rest::binary>>} = File.read(response.audio_file)
    assert response.output_resource_uri == "file://[REDACTED_AUDIO_PATH]"
    assert response.voice_metadata.output_resource_uri == "file://[REDACTED_AUDIO_PATH]"
    assert response.voice_metadata.provider_profile == "voice_tts_fake"
    assert response.voice_metadata.provider == "fake_voice"
    assert response.voice_metadata.model == "fake-tts-v1"
    assert response.voice_metadata.output_format == "wav"
    assert response.voice_metadata.usage == %{source: :unavailable}
    assert response.voice_metadata.cost == %{source: :unavailable}
    assert response.voice_metadata.redaction_status == "redacted"

    assert [%{name: "synthesize_voice", status: :completed, voice_metadata: action_metadata}] =
             response.actions

    assert action_metadata.output_resource_uri == "file://[REDACTED_AUDIO_PATH]"
  end

  test "voice synthesis is default-off until operator enables it" do
    assert {:ok, response} = SynthesizeVoice.run(%{text: "hello"}, context())

    assert response.status == :denied
    assert response.error == :voice_disabled
    refute Map.has_key?(response, :audio_file)
  end

  test "empty text is denied before synthesis" do
    enable_voice!()

    assert {:ok, response} = SynthesizeVoice.run(%{text: "   "}, context())

    assert response.status == :denied
    assert response.error == :missing_text
  end

  defp enable_voice! do
    assert {:ok, _resolved} = Settings.put("voice.enabled", true, %{audit?: false})
  end

  defp use_fake_tts! do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.text_to_speech", ["voice_tts_fake"], %{
               audit?: false
             })
  end

  defp context do
    %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}
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
