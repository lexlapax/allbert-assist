defmodule AllbertAssist.Actions.TranscribeVoiceTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Actions.Voice.TranscribeVoice
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
        "allbert-transcribe-voice-#{System.unique_integer([:positive])}"
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

  test "fake STT provider transcribes a bounded local fixture" do
    enable_voice!()
    use_fake_stt!()
    fixture = fixture_path("hello.wav")

    assert {:ok, response} = TranscribeVoice.run(%{audio_file: fixture}, context())

    assert response.status == :completed
    assert response.transcript == "hello from fixture audio"
    assert response.permission_decision.decision == :allowed
    assert response.voice_metadata.resource_uri == "file://[REDACTED_AUDIO_PATH]"
    assert response.voice_metadata.provider_profile == "voice_stt_fake"
    assert response.voice_metadata.provider == "fake_voice"
    assert response.voice_metadata.model == "fake-stt-v1"
    assert response.voice_metadata.audio_format == "wav"
    assert Map.has_key?(response.voice_metadata, :duration_ms)
    assert response.voice_metadata.usage == %{source: :unavailable}
    assert response.voice_metadata.cost == %{source: :unavailable}
    assert response.voice_metadata.redaction_status == "redacted"
    assert is_binary(response.voice_metadata.transcript_sha256)

    assert [%{name: "transcribe_voice", status: :completed, voice_metadata: action_metadata}] =
             response.actions

    assert action_metadata.resource_uri == "file://[REDACTED_AUDIO_PATH]"
    refute inspect(response) =~ fixture
    refute inspect(response) =~ "/fixtures/v0.48/audio"
  end

  test "approved remote STT confirmation returns redacted target error output data" do
    enable_voice!()
    use_openai_stt!()

    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-openai", %{
               audit?: false
             })

    assert {:ok, pending} =
             Runner.run(
               "transcribe_voice",
               %{audio_file: fixture_path("hello.wav")},
               context()
             )

    assert pending.status == :needs_confirmation
    assert pending.confirmation_id

    Req.Test.expect(__MODULE__, fn %{request_path: "/v1/audio/transcriptions"} = conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test-openai"]

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(400, Jason.encode!(%{"error" => %{"message" => "bad audio"}}))
    end)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "fixture STT denial"},
               context()
               |> Map.put(:req_options, plug: {Req.Test, __MODULE__})
               |> Map.put(:transcode_runner, :copy)
             )

    assert approved.status == :completed
    assert approved.output_data.status == :error
    assert approved.output_data.error == {:voice_http_error, 400}
    assert approved.output_data.message =~ "Voice transcription failed"
    assert approved.confirmation["operator_resolution"]["target_status"] == "error"

    assert approved.confirmation["operator_resolution"]["target_result"]["error"] ==
             {:voice_http_error, 400}
  end

  test "voice transcription is default-off until operator enables it" do
    assert {:ok, response} =
             TranscribeVoice.run(%{audio_file: fixture_path("hello.wav")}, context())

    assert response.status == :denied
    assert response.error == :voice_disabled
    refute Map.has_key?(response, :transcript)
  end

  test "oversize and unsupported files are denied before transcription", %{home: home} do
    enable_voice!()
    use_fake_stt!()
    too_large = Path.join(home, "large.wav")
    unsupported = Path.join(home, "notes.txt")
    File.write!(too_large, "12345")
    File.write!(unsupported, "not audio")

    assert {:ok, _resolved} = Settings.put("voice.audio.max_bytes", 4, %{audit?: false})

    assert {:ok, too_large_response} = TranscribeVoice.run(%{audio_file: too_large}, context())
    assert too_large_response.status == :denied
    assert too_large_response.error == {:audio_input_too_large, 5, 4}
    refute Map.has_key?(too_large_response, :transcript)
    refute inspect(too_large_response) =~ too_large

    assert {:ok, _resolved} = Settings.put("voice.audio.max_bytes", 10_485_760, %{audit?: false})

    assert {:ok, unsupported_response} =
             TranscribeVoice.run(%{audio_file: unsupported}, context())

    assert unsupported_response.status == :denied
    assert unsupported_response.error == {:unsupported_audio_file_type, ".txt"}
    refute Map.has_key?(unsupported_response, :transcript)
    refute inspect(unsupported_response) =~ unsupported
  end

  defp enable_voice! do
    assert {:ok, _resolved} = Settings.put("voice.enabled", true, %{audit?: false})
  end

  defp use_fake_stt! do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.speech_to_text", ["voice_stt_fake"], %{
               audit?: false
             })
  end

  defp use_openai_stt! do
    assert {:ok, _provider} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.speech_to_text",
               ["voice_stt_openai"],
               %{
                 audit?: false
               }
             )
  end

  defp context do
    %{actor: "local", channel: :cli, request: %{operator_id: "local", channel: :cli}}
  end

  defp fixture_path(name) do
    Path.expand("../../fixtures/v0.48/audio/#{name}", __DIR__)
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
