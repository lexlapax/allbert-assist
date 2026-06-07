defmodule AllbertAssist.Settings.ProviderCatalogTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Settings.ProviderCatalog

  test "catalog profiles declare validated capabilities and media metadata" do
    assert :ok = ProviderCatalog.validate_catalog()

    known_capabilities = MapSet.new(ProviderCatalog.known_capabilities())
    profiles = ProviderCatalog.model_profiles()

    assert "speech_to_text" in ProviderCatalog.known_capabilities()
    assert "text_to_speech" in ProviderCatalog.known_capabilities()
    assert "vision_input" in ProviderCatalog.known_capabilities()
    assert "image_generation" in ProviderCatalog.known_capabilities()

    for {name, profile} <- profiles do
      capabilities = Map.fetch!(profile, "capabilities")

      assert capabilities != []

      assert MapSet.subset?(MapSet.new(capabilities), known_capabilities),
             "#{name} declares an unknown capability"

      assert is_map(Map.get(profile, "media", %{}))
    end

    for {_name, profile} <- profiles,
        "speech_to_text" not in profile["capabilities"],
        "text_to_speech" not in profile["capabilities"],
        "vision_input" not in profile["capabilities"],
        "image_generation" not in profile["capabilities"] do
      assert "text_generation" in profile["capabilities"]
    end
  end

  test "voice profiles are descriptive settings defaults, not Jido text aliases" do
    profiles = ProviderCatalog.model_profiles()
    stt = profiles["voice_stt_fake"]
    tts = profiles["voice_tts_fake"]
    local_stt = profiles["voice_stt_local"]
    openai_tts = profiles["voice_tts_openai"]
    gemini_tts = profiles["voice_tts_gemini"]

    assert stt["capabilities"] == ["speech_to_text"]
    assert stt["media"]["input_modalities"] == ["audio"]
    assert stt["media"]["output_modalities"] == ["text"]
    assert stt["media"]["deployment_mode"] == "fake"

    assert tts["capabilities"] == ["text_to_speech"]
    assert tts["media"]["input_modalities"] == ["text"]
    assert tts["media"]["output_modalities"] == ["audio"]
    assert tts["media"]["deployment_mode"] == "fake"

    assert local_stt["provider"] == "local_voice"
    assert local_stt["media"]["deployment_mode"] == "local_endpoint"
    assert openai_tts["provider"] == "openai"
    assert openai_tts["media"]["deployment_mode"] == "remote_credentialed"
    assert gemini_tts["provider"] == "gemini"
    assert gemini_tts["model"] == "gemini-3.1-flash-tts-preview"

    aliases = ProviderCatalog.jido_model_aliases()
    refute Map.has_key?(aliases, :voice_stt_fake)
    refute Map.has_key?(aliases, :voice_tts_fake)
    refute Map.has_key?(aliases, :voice_stt_local)
    refute Map.has_key?(aliases, :voice_tts_local)
    refute Map.has_key?(aliases, :voice_stt_openai)
    refute Map.has_key?(aliases, :voice_tts_openai)
    refute Map.has_key?(aliases, :voice_stt_gemini)
    refute Map.has_key?(aliases, :voice_tts_gemini)
    assert aliases.voice_text_local == "openai:llama3.2:3b"
  end

  test "capability and media validators reject unknown authority-shaped metadata" do
    assert {:error, {:unknown_capability, ["shell_execute"]}} =
             ProviderCatalog.validate_capabilities(["text_generation", "shell_execute"])

    assert {:error, {:unknown_media_field, "permission"}} =
             ProviderCatalog.validate_media(%{"permission" => "allowed"})

    assert {:error, {:invalid_deployment_mode, "auto_granted"}} =
             ProviderCatalog.validate_media(%{"deployment_mode" => "auto_granted"})

    assert {:error, {:invalid_image_formats_supported, []}} =
             ProviderCatalog.validate_media(%{"image_formats_supported" => []})

    assert {:error, {:invalid_positive_integer, "max_image_bytes", 0}} =
             ProviderCatalog.validate_media(%{"max_image_bytes" => 0})
  end

  test "vision and image profiles are descriptive settings defaults" do
    profiles = ProviderCatalog.model_profiles()

    vision_openai = profiles["vision_openai"]
    vision_gemini = profiles["vision_gemini"]
    vision_fake = profiles["vision_fake"]
    image_openai = profiles["image_openai"]
    image_gemini = profiles["image_gemini"]
    image_fake = profiles["image_fake"]

    assert vision_openai["provider"] == "openai"
    assert vision_openai["model"] == "gpt-5.2"
    assert vision_openai["capabilities"] == ["text_generation", "vision_input"]
    assert vision_openai["media"]["input_modalities"] == ["text", "image"]
    assert vision_openai["media"]["output_modalities"] == ["text"]
    assert vision_openai["media"]["deployment_mode"] == "remote_credentialed"
    assert "png" in vision_openai["media"]["image_formats_supported"]

    assert vision_gemini["provider"] == "gemini"
    assert vision_gemini["model"] == "gemini-2.5-flash"
    assert vision_gemini["capabilities"] == ["text_generation", "vision_input"]

    assert vision_fake["provider"] == "fake_media"
    assert vision_fake["capabilities"] == ["vision_input"]
    assert vision_fake["media"]["deployment_mode"] == "fake"

    assert image_openai["provider"] == "openai"
    assert image_openai["model"] == "gpt-image-1.5"
    assert image_openai["capabilities"] == ["image_generation"]
    assert image_openai["media"]["output_modalities"] == ["image"]

    assert image_gemini["provider"] == "gemini"
    assert image_gemini["model"] == "gemini-3.1-flash-image"
    assert image_gemini["capabilities"] == ["image_generation"]

    assert image_fake["provider"] == "fake_media"
    assert image_fake["capabilities"] == ["image_generation"]
    assert image_fake["media"]["deployment_mode"] == "fake"

    aliases = ProviderCatalog.jido_model_aliases()
    assert aliases.vision_openai == "openai:gpt-5.2"
    assert aliases.vision_gemini == "google:gemini-2.5-flash"
    refute Map.has_key?(aliases, :vision_fake)
    refute Map.has_key?(aliases, :image_openai)
    refute Map.has_key?(aliases, :image_gemini)
    refute Map.has_key?(aliases, :image_fake)
  end
end
