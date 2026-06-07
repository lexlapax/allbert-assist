defmodule AllbertAssist.Security.V048VoiceModalityEvalTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :security_eval_serial
  @moduletag :home_fs_serial
  @moduletag :app_env_serial
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry, as: ActionsRegistry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Channels
  alias AllbertAssist.Channels.Telegram.Adapter
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.SecurityFixtures.EvalInventory
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Settings.Secrets
  alias AllbertAssist.Trace
  alias AllbertAssist.Voice.ProviderAdapter
  alias AllbertAssist.Voice.ProviderHTTP
  alias AllbertAssist.Voice.Transcode
  alias Plug.Conn.Query

  setup {Req.Test, :verify_on_exit!}

  @eval_ids [
    "voice-provider-capability-no-authority-001",
    "voice-preference-fallback-capability-check-001",
    "voice-cli-file-bounds-001",
    "voice-mic-confirmation-001",
    "voice-audio-retention-default-off-001",
    "voice-trace-redaction-001",
    "voice-cloud-upload-policy-001",
    "voice-tts-cost-metadata-display-only-001",
    "voice-channel-authority-boundary-001",
    "voice-transcode-bounded-001",
    "voice-local-endpoint-loopback-only-001",
    "voice-remote-https-secret-only-001",
    "voice-anthropic-not-stt-tts-001",
    "voice-transcode-materialized-bound-001",
    "voice-call-failure-fallback-bounded-001",
    "voice-listen-think-speak-routing-001"
  ]

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_plugins = PluginRegistry.registered_plugins()
    original_runtime_config = Application.get_env(:allbert_assist, Runtime)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_trace_config = Application.get_env(:allbert_assist, Trace)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Confirmations)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Runtime)
    Application.delete_env(:allbert_assist, Settings)
    Application.delete_env(:allbert_assist, Trace)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-v048-voice-eval-#{System.unique_integer([:positive])}"
      )

    System.put_env("ALLBERT_HOME", home)
    PluginRegistry.clear()

    assert {:ok, "allbert.telegram"} =
             PluginRegistry.register_module(AllbertAssist.Plugins.Telegram)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Confirmations, original_confirmations_config)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Runtime, original_runtime_config)
      restore_app_env(Settings, original_settings_config)
      restore_app_env(Trace, original_trace_config)
      PluginRegistry.clear()
      Enum.each(original_plugins, &PluginRegistry.register_entry/1)
    end)

    {:ok, home: home, context: context()}
  end

  test "v0.48 eval inventory rows are complete" do
    rows = EvalInventory.rows_for_milestone(:v048)

    assert Enum.map(rows, & &1.id) == @eval_ids
    assert Enum.all?(rows, &(&1.surface == :voice_modality))
    assert Enum.all?(rows, &(&1.test_module == inspect(__MODULE__)))
  end

  test "voice capability metadata routes requests but does not grant authority" do
    assert_eval!("voice-provider-capability-no-authority-001")
    assert_eval!("voice-preference-fallback-capability-check-001")

    assert {:ok, stt} = Models.for(:speech_to_text)
    assert stt.profile.name == "voice_stt_local"
    assert stt.profile.capabilities == ["speech_to_text"]
    assert stt.profile.media["deployment_mode"] == "local_endpoint"

    remote =
      PermissionGate.authorize(:voice_transcribe, %{
        provider_deployment_mode: :remote_credentialed
      })

    assert remote.decision == :needs_confirmation

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["voice_stt_fake", "local"], %{
               audit?: false
             })

    assert {:ok, resolution} = Models.for(:direct_answer)
    assert resolution.profile.name == "local"

    assert Enum.any?(
             resolution.diagnostics,
             &match?(
               %{reason: {:profile_missing_capability, "voice_stt_fake", "text_generation"}},
               &1
             )
           )
  end

  test "audio file, retention, redaction, and transcode bounds are enforced", %{
    home: home,
    context: context
  } do
    assert_eval!("voice-cli-file-bounds-001")
    assert_eval!("voice-audio-retention-default-off-001")
    assert_eval!("voice-trace-redaction-001")
    assert_eval!("voice-transcode-bounded-001")
    enable_voice!()
    use_fake_stt!()

    fixture = fixture_path("hello.wav")

    assert {:ok, response} = Runner.run("transcribe_voice", %{audio_file: fixture}, context)
    assert response.status == :completed
    assert response.voice_metadata.resource_uri == "file://[REDACTED_AUDIO_PATH]"
    refute inspect(response) =~ fixture

    assert {:ok, false} = Settings.get("voice.audio.retention_enabled")
    refute File.exists?(Path.join(home, "audio"))

    redacted =
      Redactor.redact_audio_metadata(%{
        resource_uri: ResourceURI.file!(fixture),
        raw_audio: "raw bytes",
        transcript: "hello from fixture audio"
      })

    assert redacted.resource_uri == "file://[REDACTED_AUDIO_PATH]"
    refute Map.has_key?(redacted, :raw_audio)
    refute Map.has_key?(redacted, :transcript)

    assert {:ok, stt} = Models.for(:speech_to_text)

    assert {:error, {:audio_input_too_long, 300_001, 300_000}} =
             Transcode.build_spec(fixture, stt.profile, duration_ms: 300_001)

    assert {:error, :arbitrary_transcode_args_not_supported} =
             Transcode.build_spec(fixture, stt.profile, args: ["-arbitrary"])

    too_large = Path.join(home, "large.wav")
    File.write!(too_large, "12345")
    assert {:ok, _setting} = Settings.put("voice.audio.max_bytes", 4, %{audit?: false})

    assert {:ok, denied} = Runner.run("transcribe_voice", %{audio_file: too_large}, context)
    assert denied.status == :denied
    assert denied.error == {:audio_input_too_large, 5, 4}
    refute inspect(denied) =~ too_large
  end

  test "workspace microphone and cloud upload paths require confirmation", %{
    home: home,
    context: context
  } do
    assert_eval!("voice-mic-confirmation-001")
    assert_eval!("voice-cloud-upload-policy-001")
    enable_voice!()

    assert {:ok, pending} =
             Runner.run(
               "capture_workspace_voice",
               %{session_id: "sess_v048", thread_id: "thr_v048", user_id: "operator"},
               context
             )

    assert pending.status == :needs_confirmation
    assert pending.permission_decision.permission == :microphone_capture
    assert pending.confirmation_id
    refute File.exists?(Path.join(home, "audio"))

    remote_transcribe =
      PermissionGate.authorize(:voice_transcribe, %{
        provider_deployment_mode: :remote_credentialed
      })

    assert remote_transcribe.decision == :needs_confirmation

    remote_synthesis =
      PermissionGate.authorize(:voice_synthesize, %{
        model_profile: %{media: %{"deployment_mode" => "remote_credentialed"}}
      })

    assert remote_synthesis.decision == :needs_confirmation
  end

  test "TTS usage and cost metadata is display-only", %{context: context} do
    assert_eval!("voice-tts-cost-metadata-display-only-001")
    enable_voice!()
    use_fake_tts!()

    assert {:ok, response} = Runner.run("synthesize_voice", %{text: "hello release"}, context)

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed
    assert response.voice_metadata.provider_profile == "voice_tts_fake"
    assert response.voice_metadata.usage == %{source: :unavailable}
    assert response.voice_metadata.cost == %{source: :unavailable}
    assert response.voice_metadata.output_resource_uri == "file://[REDACTED_AUDIO_PATH]"
  end

  test "Telegram voice notes fetch channel media but delegate STT authority to actions" do
    assert_eval!("voice-channel-authority-boundary-001")
    enable_voice!()
    use_fake_stt!()
    configure_telegram!(identity_map: [%{external_user_id: "123", user_id: "alice"}])
    configure_runtime!()

    Req.Test.stub(__MODULE__, fn
      %{request_path: "/bottoken/getUpdates"} = conn ->
        query = Query.decode(conn.query_string)
        assert query["allowed_updates"] == Jason.encode!(["message", "callback_query"])
        json(conn, %{"ok" => true, "result" => [voice_update(480)]})

      %{request_path: "/bottoken/getFile"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["file_id"] == "voice-file-480"

        json(conn, %{
          "ok" => true,
          "result" => %{"file_path" => "voice/hello.ogg", "file_size" => 16}
        })

      %{request_path: "/file/bottoken/voice/hello.ogg"} = conn ->
        conn
        |> Plug.Conn.put_resp_content_type("audio/ogg")
        |> Plug.Conn.send_resp(200, "telegram voice fixture")

      %{request_path: "/bottoken/sendMessage"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert Jason.decode!(body)["text"] =~ "Runtime response:"
        json(conn, %{"ok" => true, "result" => %{"message_id" => 480}})
    end)

    assert {:ok, capability} = ActionsRegistry.capability("transcribe_voice")
    assert capability.permission == :voice_transcribe
    refute ActionsRegistry.registered_module?(Adapter)

    server = :"telegram-v048-voice-#{System.unique_integer([:positive])}"

    pid =
      start_supervised!(
        {Adapter, name: server, auto_poll?: false, req_options: [plug: {Req.Test, __MODULE__}]}
      )

    Req.Test.allow(__MODULE__, self(), pid)

    assert {:ok, %{processed: 1, rejected: 0, failed: 0}} = Adapter.poll_once(server)

    event = Channels.get_event_by_external_id("telegram", "480")
    assert event.status == "processed"

    assert_received {:runtime_request, %{channel: "telegram", user_id: "alice"} = request}
    assert request.text =~ "transcribed fixture audio"
    assert request.metadata.voice.provider_profile == "voice_stt_fake"
    assert request.metadata.telegram_voice.file_id == "voice-file-480"
    assert request.metadata.telegram_voice.file_unique_id == "voice-unique-480"
    refute inspect(request.metadata) =~ "telegram voice fixture"
    refute inspect(request.metadata) =~ "bottoken"
    refute inspect(request.metadata) =~ "/telegram-voice/"
  end

  test "voice provider HTTP policy and native capability checks are fail closed" do
    assert_eval!("voice-local-endpoint-loopback-only-001")
    assert_eval!("voice-remote-https-secret-only-001")
    assert_eval!("voice-anthropic-not-stt-tts-001")

    assert {:ok, %{url: "http://127.0.0.1:5050/v1/models"}} =
             ProviderHTTP.endpoint(local_stt_profile(), "/models")

    assert {:error, {:voice_local_host_denied, "192.168.1.10"}} =
             local_stt_profile()
             |> Map.put(:provider_base_url, "http://192.168.1.10:5050/v1")
             |> ProviderHTTP.endpoint("/models")

    assert {:error, {:voice_local_host_denied, "169.254.169.254"}} =
             local_stt_profile()
             |> Map.put(:provider_base_url, "http://169.254.169.254/v1")
             |> ProviderHTTP.endpoint("/models")

    assert {:error, {:voice_remote_https_required, "http"}} =
             openai_tts_profile()
             |> Map.put(:provider_base_url, "http://api.openai.test/v1")
             |> ProviderHTTP.endpoint("/models")

    assert {:error, {:voice_remote_host_denied, :private_host}} =
             openai_tts_profile()
             |> Map.put(:provider_base_url, "https://[::ffff:10.0.0.1]/v1")
             |> ProviderHTTP.endpoint("/models")

    assert {:error, {:voice_remote_host_denied, :private_host}} =
             openai_tts_profile()
             |> Map.put(:provider_base_url, "https://[::ffff:169.254.169.254]/v1")
             |> ProviderHTTP.endpoint("/models")

    assert {:error, :voice_endpoint_credentials_in_url_denied} =
             openai_tts_profile()
             |> Map.put(:provider_base_url, "https://token@example.test/v1")
             |> ProviderHTTP.endpoint("/models")

    assert {:error, {:voice_credential_missing, "openai"}} =
             ProviderHTTP.endpoint(openai_tts_profile(), "/models")

    assert {:ok, _secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-v048", %{
               audit?: false
             })

    assert {:ok, %{url: "https://api.openai.com/v1/models"}} =
             ProviderHTTP.endpoint(openai_tts_profile(), "/models")

    assert {:error, {:voice_capability_not_native, "anthropic"}} =
             ProviderAdapter.transcribe(
               %{
                 provider_type: "anthropic",
                 media: %{"deployment_mode" => "remote_credentialed"}
               },
               %{input_path: "/tmp/voice.wav", transcode_spec: %{}}
             )
  end

  test "real provider adapters use materialized transcode output and current request shapes", %{
    home: home
  } do
    assert_eval!("voice-transcode-materialized-bound-001")

    assert {:ok, _openai_secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-openai", %{
               audit?: false
             })

    assert {:ok, _gemini_secret} =
             Secrets.put_secret("secret://providers/gemini/api_key", "AIza-test-gemini", %{
               audit?: false
             })

    materialized_audio = "materialized audio"

    Req.Test.stub(__MODULE__, fn
      %{request_path: "/v1/audio/transcriptions"} = conn ->
        body = Req.Test.raw_body(conn)
        assert body =~ materialized_audio
        assert body =~ "whisper-local"
        json(conn, %{"text" => "hello local voice"})

      %{request_path: "/v1/audio/speech"} = conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test-openai"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "gpt-4o-mini-tts"
        assert decoded["input"] == "speak this"
        assert decoded["response_format"] == "wav"

        conn
        |> Plug.Conn.put_resp_content_type("audio/wav")
        |> Plug.Conn.send_resp(200, wav_bytes())

      %{request_path: "/v1beta/interactions"} = conn ->
        assert Plug.Conn.get_req_header(conn, "x-goog-api-key") == ["AIza-test-gemini"]
        assert Plug.Conn.get_req_header(conn, "api-revision") == ["2026-05-20"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["model"] == "gemini-3.5-flash"
        audio_part = Enum.find(decoded["input"], &(&1["type"] == "audio"))
        assert {:ok, ^materialized_audio} = Base.decode64(audio_part["data"])

        json(conn, %{
          "output_text" => "hello gemini voice",
          "usageMetadata" => %{
            "promptTokenCount" => 11,
            "candidatesTokenCount" => 3,
            "totalTokenCount" => 14
          }
        })

      %{request_path: "/v1beta/models/gemini-3.1-flash-tts-preview:generateContent"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        decoded = Jason.decode!(body)
        assert decoded["generationConfig"]["responseModalities"] == ["AUDIO"]

        assert decoded["generationConfig"]["speechConfig"]["voiceConfig"]["prebuiltVoiceConfig"][
                 "voiceName"
               ] == "Kore"

        json(conn, %{
          "candidates" => [
            %{
              "content" => %{
                "parts" => [
                  %{
                    "inlineData" => %{
                      "mimeType" => "audio/pcm",
                      "data" => Base.encode64(<<0, 0, 0, 0>>)
                    }
                  }
                ]
              }
            }
          ],
          "usageMetadata" => %{
            "promptTokenCount" => 5,
            "candidatesTokenCount" => 2,
            "totalTokenCount" => 7
          }
        })
    end)

    input_path = Path.join(home, "input.wav")
    File.write!(input_path, "original audio")

    {:ok, transcode_spec} =
      Transcode.build_spec(input_path, local_stt_profile(), output_root: home)

    runner = fn spec ->
      File.write!(spec.output_path, materialized_audio)
      :ok
    end

    assert {:ok, transcript} =
             ProviderAdapter.transcribe(
               local_stt_profile(),
               %{input_path: input_path, transcode_spec: transcode_spec},
               req_options: [plug: {Req.Test, __MODULE__}],
               transcode_runner: runner
             )

    assert transcript.transcript == "hello local voice"

    assert {:ok, openai_audio} =
             ProviderAdapter.synthesize(
               openai_tts_profile(),
               %{text: "speak this", output_format: "wav", voice: "alloy"},
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert {:ok, <<"RIFF", _rest::binary>>} = File.read(openai_audio.path)

    {:ok, gemini_spec} = Transcode.build_spec(input_path, gemini_stt_profile(), output_root: home)

    assert {:ok, gemini_transcript} =
             ProviderAdapter.transcribe(
               gemini_stt_profile(),
               %{input_path: input_path, transcode_spec: gemini_spec},
               req_options: [plug: {Req.Test, __MODULE__}],
               transcode_runner: runner
             )

    assert gemini_transcript.transcript == "hello gemini voice"
    assert gemini_transcript.usage["source"] == "provider"
    assert gemini_transcript.usage["totalTokenCount"] == 14

    assert {:ok, gemini_audio} =
             ProviderAdapter.synthesize(
               gemini_tts_profile(),
               %{text: "hello", output_format: "wav", voice: "Kore"},
               req_options: [plug: {Req.Test, __MODULE__}]
             )

    assert {:ok, <<"RIFF", _rest::binary>>} = File.read(gemini_audio.path)
    assert gemini_audio.usage["source"] == "provider"
    assert gemini_audio.usage["totalTokenCount"] == 7
  end

  test "voice fallback is bounded and listen think speak routes through Ollama text profile", %{
    context: context
  } do
    assert_eval!("voice-call-failure-fallback-bounded-001")
    assert_eval!("voice-listen-think-speak-routing-001")

    install_fake_retryable_stt!()
    enable_voice!()

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.speech_to_text",
               ["voice_stt_fake_retryable", "voice_stt_fake"],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["voice_text_local"], %{
               audit?: false
             })

    use_fake_tts!()

    assert {:ok, response} =
             Runner.run("transcribe_voice", %{audio_file: fixture_path("hello.wav")}, context)

    assert response.status == :completed
    assert response.voice_metadata.provider_profile == "voice_stt_fake"

    assert [%{provider_profile: "voice_stt_fake_retryable", error: {:voice_http_error, 503}}] =
             response.voice_metadata.fallback_attempts

    assert {:ok, text_resolution} = Models.for(:direct_answer)
    assert text_resolution.profile.name == "voice_text_local"

    assert {:ok, tts} = Runner.run("synthesize_voice", %{text: "Runtime response"}, context)
    assert tts.status == :completed
    assert tts.voice_metadata.provider_profile == "voice_tts_fake"

    install_fake_nonretryable_stt!()
    enable_voice!()

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.speech_to_text",
               ["voice_stt_fake_nonretryable", "voice_stt_fake"],
               %{audit?: false}
             )

    assert {:ok, stopped} =
             Runner.run("transcribe_voice", %{audio_file: fixture_path("hello.wav")}, context)

    assert stopped.status == :error
    assert stopped.error == {:voice_http_error, 401}

    assert [%{provider_profile: "voice_stt_fake_nonretryable", error: {:voice_http_error, 401}}] =
             stopped.voice_metadata.adapter_attempts

    install_fake_retryable_stt!()
    enable_voice!()

    assert {:ok, _provider} = Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _openai_secret} =
             Secrets.put_secret("secret://providers/openai/api_key", "sk-test-openai", %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.capabilities.speech_to_text",
               ["voice_stt_fake_retryable", "voice_stt_openai"],
               %{audit?: false}
             )

    voice_context =
      Map.put(context, :voice_adapter_opts,
        req_options: [plug: {Req.Test, __MODULE__}],
        transcode_runner: :copy
      )

    assert {:ok, needs_confirmation} =
             Runner.run(
               "transcribe_voice",
               %{audio_file: fixture_path("hello.wav")},
               voice_context
             )

    assert needs_confirmation.status == :needs_confirmation
    assert needs_confirmation.error == :permission_denied
    assert needs_confirmation.permission_decision.decision == :needs_confirmation
    assert needs_confirmation.confirmation_id

    assert [%{provider_profile: "voice_stt_fake_retryable", error: "{:voice_http_error, 503}"}] =
             needs_confirmation.voice_metadata.fallback_attempts

    assert needs_confirmation.confirmation["resume_params_ref"]["audio_file"] ==
             "[REDACTED_AUDIO_PATH]"

    refute inspect(needs_confirmation.confirmation) =~ fixture_path("hello.wav")

    assert {:ok, shown} =
             Runner.run("show_confirmation", %{id: needs_confirmation.confirmation_id}, context)

    assert shown.confirmation["resume_params_ref"]["audio_file"] == "[REDACTED_AUDIO_PATH]"
    refute inspect(shown.confirmation) =~ fixture_path("hello.wav")

    Req.Test.expect(__MODULE__, fn
      %{request_path: "/v1/audio/transcriptions"} = conn ->
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer sk-test-openai"]
        assert Req.Test.raw_body(conn) =~ "gpt-4o-mini-transcribe"
        json(conn, %{"text" => "approved remote voice", "usage" => %{"total_tokens" => 9}})
    end)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: needs_confirmation.confirmation_id, reason: "fixture provider approved"},
               voice_context
             )

    assert approved.status == :completed
    assert approved.confirmation["status"] == "approved"
    assert approved.output_data.transcript == "approved remote voice"
    assert approved.confirmation["operator_resolution"]["target_resumed?"] == true
    assert approved.confirmation["operator_resolution"]["target_status"] == "completed"
    assert approved.confirmation["operator_resolution"]["target_result"]["status"] == "completed"

    refute inspect(approved.confirmation["operator_resolution"]["target_result"]) =~
             "approved remote voice"
  end

  defp assert_eval!(id), do: EvalInventory.row!(id)

  defp enable_voice! do
    assert {:ok, _setting} = Settings.put("voice.enabled", true, %{audit?: false})
  end

  defp use_fake_stt! do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.speech_to_text", ["voice_stt_fake"], %{
               audit?: false
             })
  end

  defp use_fake_tts! do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.text_to_speech", ["voice_tts_fake"], %{
               audit?: false
             })
  end

  defp install_fake_retryable_stt! do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "model_profiles" => %{
                 "voice_stt_fake_retryable" => %{
                   "provider" => "fake_voice",
                   "model" => "fake-stt-retryable-error",
                   "capabilities" => ["speech_to_text"],
                   "media" => %{
                     "input_modalities" => ["audio"],
                     "output_modalities" => ["text"],
                     "transport_modes" => ["request_file"],
                     "deployment_mode" => "fake",
                     "audio_formats_supported" => ["wav"],
                     "audio_sample_rates_supported" => [16_000],
                     "max_audio_bytes" => 10_485_760,
                     "max_audio_duration_ms" => 300_000
                   },
                   "temperature" => 0.0,
                   "max_tokens" => 1024,
                   "timeout_ms" => 30_000
                 }
               }
             })
  end

  defp install_fake_nonretryable_stt! do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "model_profiles" => %{
                 "voice_stt_fake_nonretryable" => %{
                   "provider" => "fake_voice",
                   "model" => "fake-stt-nonretryable-error",
                   "capabilities" => ["speech_to_text"],
                   "media" => %{
                     "input_modalities" => ["audio"],
                     "output_modalities" => ["text"],
                     "transport_modes" => ["request_file"],
                     "deployment_mode" => "fake",
                     "audio_formats_supported" => ["wav"],
                     "audio_sample_rates_supported" => [16_000],
                     "max_audio_bytes" => 10_485_760,
                     "max_audio_duration_ms" => 300_000
                   },
                   "temperature" => 0.0,
                   "max_tokens" => 1024,
                   "timeout_ms" => 30_000
                 }
               }
             })
  end

  defp configure_telegram!(opts) do
    assert {:ok, _secret} =
             Secrets.put_secret("secret://channels/telegram/bot_token", "token", %{audit?: false})

    assert {:ok, _setting} = Settings.put("channels.telegram.enabled", true, %{audit?: false})

    identity_map = Keyword.get(opts, :identity_map, [])

    assert {:ok, _setting} =
             Settings.put("channels.telegram.identity_map", identity_map, %{audit?: false})
  end

  defp configure_runtime! do
    parent = self()
    Application.put_env(:allbert_assist, Trace, enabled: true)

    Application.put_env(:allbert_assist, Runtime,
      agent_runner: fn _signal, request ->
        send(parent, {:runtime_request, request})
        {:ok, %{message: "Runtime response: #{request.text}", status: :completed}}
      end
    )
  end

  defp context do
    %{
      actor: "operator",
      user_id: "operator",
      channel: :test,
      surface: "v048_eval",
      request: %{operator_id: "operator", channel: :test}
    }
  end

  defp fixture_path(name) do
    Path.expand("../fixtures/v0.48/audio/#{name}", __DIR__)
  end

  defp voice_update(update_id) do
    %{
      "update_id" => update_id,
      "message" => %{
        "message_id" => 10,
        "from" => %{"id" => 123},
        "chat" => %{"id" => 456, "type" => "private"},
        "voice" => %{
          "file_id" => "voice-file-#{update_id}",
          "file_unique_id" => "voice-unique-#{update_id}",
          "duration" => 2,
          "mime_type" => "audio/ogg",
          "file_size" => 16
        }
      }
    }
  end

  defp local_stt_profile do
    %{
      name: "voice_stt_local",
      provider: "local_voice",
      provider_type: "openai_compatible",
      provider_endpoint_kind: "local_endpoint",
      provider_base_url: "http://127.0.0.1:5050/v1",
      model: "whisper-local",
      capabilities: ["speech_to_text"],
      media: %{
        "deployment_mode" => "local_endpoint",
        "audio_formats_supported" => ["wav"],
        "max_audio_bytes" => 10_485_760,
        "max_audio_duration_ms" => 300_000
      },
      timeout_ms: 30_000
    }
  end

  defp openai_tts_profile do
    %{
      name: "voice_tts_openai",
      provider: "openai",
      provider_type: "openai",
      provider_endpoint_kind: "credentialed_remote",
      provider_base_url: nil,
      provider_api_key_ref: "secret://providers/openai/api_key",
      model: "gpt-4o-mini-tts",
      capabilities: ["text_to_speech"],
      media: %{
        "deployment_mode" => "remote_credentialed",
        "audio_formats_supported" => ["wav"],
        "max_audio_bytes" => 10_485_760,
        "max_audio_duration_ms" => 300_000
      },
      timeout_ms: 30_000
    }
  end

  defp gemini_stt_profile do
    %{
      name: "voice_stt_gemini",
      provider: "gemini",
      provider_type: "google",
      provider_endpoint_kind: "credentialed_remote",
      provider_base_url: nil,
      provider_api_key_ref: "secret://providers/gemini/api_key",
      model: "gemini-3.5-flash",
      capabilities: ["speech_to_text"],
      media: %{
        "deployment_mode" => "remote_credentialed",
        "audio_formats_supported" => ["wav"],
        "max_audio_bytes" => 10_485_760,
        "max_audio_duration_ms" => 300_000
      },
      timeout_ms: 30_000
    }
  end

  defp gemini_tts_profile do
    %{
      name: "voice_tts_gemini",
      provider: "gemini",
      provider_type: "google",
      provider_endpoint_kind: "credentialed_remote",
      provider_base_url: nil,
      provider_api_key_ref: "secret://providers/gemini/api_key",
      model: "gemini-3.1-flash-tts-preview",
      capabilities: ["text_to_speech"],
      media: %{
        "deployment_mode" => "remote_credentialed",
        "audio_formats_supported" => ["wav"],
        "max_audio_bytes" => 10_485_760,
        "max_audio_duration_ms" => 300_000
      },
      timeout_ms: 30_000
    }
  end

  defp wav_bytes do
    "RIFF" <>
      <<40::little-unsigned-integer-size(32)>> <>
      "WAVEfmt " <>
      <<16::little-unsigned-integer-size(32)>> <>
      <<1::little-unsigned-integer-size(16)>> <>
      <<1::little-unsigned-integer-size(16)>> <>
      <<16_000::little-unsigned-integer-size(32)>> <>
      <<32_000::little-unsigned-integer-size(32)>> <>
      <<2::little-unsigned-integer-size(16)>> <>
      <<16::little-unsigned-integer-size(16)>> <>
      "data" <>
      <<4::little-unsigned-integer-size(32)>> <>
      <<0, 0, 0, 0>>
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
