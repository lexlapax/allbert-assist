defmodule AllbertAssist.Settings.ModelPreferencesTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.ModelRuntime
  alias AllbertAssist.Settings.Models

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY",
    "ALLBERT_VAULT_BACKEND",
    "ANTHROPIC_API_KEY",
    "OPENAI_API_KEY",
    "OPENROUTER_API_KEY",
    "GOOGLE_API_KEY",
    "GEMINI_API_KEY",
    "OLLAMA_BASE_URL"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    System.put_env("ALLBERT_VAULT_BACKEND", "env")
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-model-preferences-#{System.unique_integer([:positive])}"
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

  test "defaults expose ranked preferences and resolve task and voice capabilities" do
    assert {:ok, 1} = Settings.get("model_preferences.schema_version")
    assert {:ok, "local"} = Settings.get("model_preferences.primary")
    assert {:ok, "local"} = Settings.get("intent.model_profile")

    assert {:ok, ["direct_answer_local"]} =
             Settings.get("model_preferences.tasks.direct_answer")

    assert {:ok, "direct_answer_local"} =
             Settings.get("intent.direct_answer_model_profile")

    assert {:ok, ["voice_stt_local", "voice_stt_openai", "voice_stt_gemini"]} =
             Settings.get("model_preferences.capabilities.speech_to_text")

    assert {:ok, ["voice_tts_local", "voice_tts_openai", "voice_tts_gemini"]} =
             Settings.get("model_preferences.capabilities.text_to_speech")

    assert {:ok, ["vision_openai", "vision_gemini"]} =
             Settings.get("model_preferences.capabilities.vision_input")

    assert {:ok, ["image_openai", "image_gemini"]} =
             Settings.get("model_preferences.capabilities.image_generation")

    assert {:ok, direct_answer} = Models.for(:direct_answer)
    assert direct_answer.request_kind == :task
    assert direct_answer.capability == "text_generation"
    assert direct_answer.profile.name == "direct_answer_local"
    assert direct_answer.profile.model == "qwen2.5:7b"
    assert direct_answer.profile.temperature == 0.0

    assert {:ok, coding} = Models.for(:coding)
    assert coding.profile.name == "coding_local"

    assert {:ok, stt} = Models.for(:speech_to_text)
    assert stt.request_kind == :capability
    assert stt.profile.name == "voice_stt_local"
    assert stt.profile.capabilities == ["speech_to_text"]
    assert stt.profile.media["deployment_mode"] == "local_endpoint"

    assert {:ok, [local_stt]} = Models.candidates_for(:speech_to_text)
    assert local_stt.profile.name == "voice_stt_local"
  end

  test "direct-answer task default does not alter unrelated model consumers" do
    assert {:ok, primary} = Models.for(:text_generation)
    assert primary.profile.name == "local"
    assert primary.profile.model == "llama3.2:3b"

    assert {:ok, coding} = Models.for(:coding)
    assert coding.profile.name == "coding_local"

    assert {:ok, pi} = Settings.resolve_model_profile("pi_coding_local")
    assert pi.model == "qwen2.5:7b"
    assert pi.temperature == 0.1
  end

  test "vision and image capability preferences resolve when a remote provider is enabled" do
    assert {:error, {:no_capable_profile, vision_diagnostic}} = Models.for(:vision_input)
    assert vision_diagnostic.candidates == ["vision_openai", "vision_gemini", "local"]

    assert {:ok, _setting} =
             Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, vision} = Models.for(:vision_input)
    assert vision.request_kind == :capability
    assert vision.profile.name == "vision_openai"
    assert vision.profile.model == "gpt-5.2"
    assert vision.profile.capabilities == ["text_generation", "vision_input"]
    assert vision.profile.media["image_formats_supported"] == ["png", "jpeg", "webp", "gif"]

    assert {:ok, image} = Models.for(:image_generation)
    assert image.request_kind == :capability
    assert image.profile.name == "image_openai"
    assert image.profile.model == "gpt-image-1.5"
    assert image.profile.capabilities == ["image_generation"]
    assert image.profile.media["output_modalities"] == ["image"]
  end

  test "local Ollama media profiles resolve only when selected explicitly" do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.vision_input", ["vision_ollama"], %{
               audit?: false
             })

    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.image_generation", ["image_ollama"], %{
               audit?: false
             })

    assert {:ok, vision} = Models.for(:vision_input)
    assert vision.request_kind == :capability
    assert vision.profile.name == "vision_ollama"
    assert vision.profile.provider == "local_ollama"
    assert vision.profile.model == "qwen3-vl:8b"
    assert vision.profile.capabilities == ["text_generation", "vision_input"]
    assert vision.profile.media["deployment_mode"] == "local_endpoint"

    assert {:ok, %{provider: :openai, id: "qwen3-vl:8b"}} =
             ModelRuntime.model_spec(vision.profile)

    assert {:ok, image} = Models.for(:image_generation)
    assert image.request_kind == :capability
    assert image.profile.name == "image_ollama"
    assert image.profile.provider == "local_ollama"
    assert image.profile.model == "x/z-image-turbo"
    assert image.profile.capabilities == ["image_generation"]
    assert image.profile.media["deployment_mode"] == "local_endpoint"

    assert {:ok, %{provider: :openai, id: "x/z-image-turbo"}} =
             ModelRuntime.model_spec(image.profile)

    assert {:ok, "openai:x/z-image-turbo"} = ModelRuntime.model_string(image.profile)

    opts = ModelRuntime.request_opts(image.profile)
    assert Keyword.fetch!(opts, :base_url) == "http://localhost:11434/v1"
    assert Keyword.fetch!(opts, :api_key) == "ollama"
  end

  test "direct-answer resolver walks the operator-authored task order" do
    assert {:ok, _setting} =
             Settings.put(
               "model_preferences.tasks.direct_answer",
               ["fast", "local"],
               %{audit?: false}
             )

    assert {:ok, resolution} = Models.for(:direct_answer)

    assert resolution.profile.name == "local"

    assert Enum.any?(
             resolution.diagnostics,
             &match?(%{reason: {:provider_disabled, "fast", "openai"}}, &1)
           )
  end

  test "an explicitly authored hosted-first direct-answer chain is not reordered" do
    assert {:ok, _setting} =
             Settings.put("providers.openai.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast", "local"], %{
               audit?: false
             })

    assert {:ok, resolution} = Models.for(:direct_answer)
    assert resolution.profile.name == "fast"
    assert resolution.diagnostics == []
  end

  test "non-empty direct-answer preferences are closed against the global primary" do
    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast"], %{
               audit?: false
             })

    assert {:error, {:no_capable_profile, diagnostic}} = Models.for(:direct_answer)
    assert diagnostic.candidates == ["fast"]

    refute Enum.any?(
             diagnostic.diagnostics,
             &match?(%{profile: "local"}, &1)
           )

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", [], %{audit?: false})

    assert {:ok, fallback} = Models.for(:direct_answer)
    assert fallback.source == :primary
    assert fallback.profile.name == "local"
  end

  test "direct-answer preferences reject profiles without text generation before writing" do
    expected_error =
      {:error,
       {:invalid_setting, "model_preferences.tasks.direct_answer",
        {:profile_missing_capability, "voice_stt_fake", "text_generation"}}}

    assert ^expected_error =
             Settings.validate({"model_preferences.tasks.direct_answer", ["voice_stt_fake"]})

    assert ^expected_error =
             Settings.put("model_preferences.tasks.direct_answer", ["voice_stt_fake"], %{
               audit?: false
             })

    assert {:ok, %{}} = Settings.read_user_settings()

    assert {:error,
            {:invalid_setting, "intent.direct_answer_model_profile",
             {:profile_missing_capability, "voice_stt_fake", "text_generation"}}} =
             Settings.validate({"intent.direct_answer_model_profile", "voice_stt_fake"})

    assert ^expected_error =
             Settings.put("intent.direct_answer_model_profile", "voice_stt_fake", %{
               audit?: false
             })

    assert {:ok, %{}} = Settings.read_user_settings()

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast", "local"], %{
               audit?: false
             })

    assert {:ok, ["fast", "local"]} =
             Settings.get("model_preferences.tasks.direct_answer")
  end

  test "legacy persisted direct-answer lists remain readable and skip incapable profiles" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "model_preferences" => %{
                 "tasks" => %{"direct_answer" => ["voice_stt_fake", "local"]}
               }
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

  test "legacy persisted text profiles without capability metadata remain runnable and selectable" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "model_profiles" => %{
                 "legacy_text" => %{
                   "provider" => "local_ollama",
                   "model" => "legacy-text:latest"
                 }
               },
               "model_preferences" => %{
                 "tasks" => %{"direct_answer" => ["legacy_text"]}
               }
             })

    assert {:ok, resolution} = Models.for(:direct_answer)
    assert resolution.profile.name == "legacy_text"
    assert resolution.profile.capabilities == []

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["legacy_text"], %{
               audit?: false
             })

    assert {:ok, ["legacy_text"]} =
             Settings.get("model_preferences.tasks.direct_answer")
  end

  test "env credential makes an explicitly selected hosted direct-answer profile resolvable" do
    System.put_env("ALLBERT_VAULT_BACKEND", "env")
    System.put_env("OPENAI_API_KEY", "operator-env-key")

    assert {:ok, false} = Settings.get("providers.openai.enabled")

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast"], %{audit?: false})

    assert {:ok, user_settings} = Settings.read_user_settings()
    assert get_in(user_settings, ["providers", "openai", "enabled"]) == nil

    assert {:ok, resolution} = Models.for(:direct_answer)
    assert resolution.profile.name == "fast"
    assert resolution.profile.provider == "openai"
    assert resolution.profile.provider_enabled
  end

  test "raw explicit provider false closes the selected direct-answer chain" do
    System.put_env("ALLBERT_VAULT_BACKEND", "env")
    System.put_env("OPENAI_API_KEY", "operator-env-key")

    assert {:ok, _setting} =
             Settings.put("providers.openai.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["fast"], %{audit?: false})

    assert {:error, {:no_capable_profile, diagnostic}} = Models.for(:direct_answer)

    assert Enum.any?(
             diagnostic.diagnostics,
             &match?(%{reason: {:provider_disabled, "fast", "openai"}}, &1)
           )

    refute Enum.any?(diagnostic.diagnostics, &match?(%{profile: "local"}, &1))
  end

  test "primary fallback is used only when the primary profile is capable" do
    assert {:ok, _setting} =
             Settings.put("model_preferences.capabilities.text_generation", [], %{audit?: false})

    assert {:ok, fallback} = Models.for(:text_generation)
    assert fallback.source == :primary
    assert fallback.profile.name == "local"

    assert {:ok, _setting} =
             Settings.put("model_preferences.primary", "voice_stt_fake", %{audit?: false})

    assert {:error, {:no_capable_profile, diagnostic}} = Models.for(:text_generation)
    assert diagnostic.candidates == ["voice_stt_fake"]

    assert [%{reason: {:profile_missing_capability, "voice_stt_fake", "text_generation"}}] =
             diagnostic.diagnostics
  end

  test "legacy intent profile keys read and write through model preferences" do
    assert {:ok, primary} =
             Settings.put("intent.model_profile", "coding_local", %{audit?: false})

    assert primary.key == "intent.model_profile"
    assert primary.value == "coding_local"
    assert {:ok, "coding_local"} = Settings.get("model_preferences.primary")
    assert {:ok, "coding_local"} = Settings.get("intent.model_profile")

    assert {:ok, _setting} =
             Settings.put("model_preferences.primary", "local", %{audit?: false})

    assert {:ok, "local"} = Settings.get("intent.model_profile")

    assert {:ok, direct_answer} =
             Settings.put("intent.direct_answer_model_profile", "fast", %{audit?: false})

    assert direct_answer.key == "intent.direct_answer_model_profile"
    assert direct_answer.value == "fast"
    assert {:ok, ["fast"]} = Settings.get("model_preferences.tasks.direct_answer")
    assert {:ok, "fast"} = Settings.get("intent.direct_answer_model_profile")

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", ["local", "fast"], %{
               audit?: false
             })

    assert {:ok, "local"} = Settings.get("intent.direct_answer_model_profile")

    assert {:ok, _setting} =
             Settings.put("model_preferences.tasks.direct_answer", [], %{audit?: false})

    assert {:ok, "local"} = Settings.get("intent.direct_answer_model_profile")
  end

  test "legacy settings files normalize into model preferences" do
    assert {:ok, _settings} =
             Settings.write_user_settings(%{
               "intent" => %{
                 "model_profile" => "coding_local",
                 "direct_answer_model_profile" => "fast"
               }
             })

    assert {:ok, "coding_local"} = Settings.get("model_preferences.primary")
    assert {:ok, ["fast"]} = Settings.get("model_preferences.tasks.direct_answer")
  end

  test "preference writes validate profile refs and capability names" do
    assert {:error, {:invalid_setting, "model_preferences.capabilities.speech_to_text", _reason}} =
             Settings.put("model_preferences.capabilities.speech_to_text", ["missing"], %{
               audit?: false
             })

    assert {:error, {:invalid_setting, "model_preferences.capabilities.shell_execute", _reason}} =
             Settings.put("model_preferences.capabilities.shell_execute", ["local"], %{
               audit?: false
             })
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
