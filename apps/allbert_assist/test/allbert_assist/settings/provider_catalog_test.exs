defmodule AllbertAssist.Settings.ProviderCatalogTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Settings.ProviderCatalog

  test "catalog profiles declare validated capabilities and media metadata" do
    assert :ok = ProviderCatalog.validate_catalog()

    known_capabilities = MapSet.new(ProviderCatalog.known_capabilities())
    profiles = ProviderCatalog.model_profiles()

    assert "speech_to_text" in ProviderCatalog.known_capabilities()
    assert "text_to_speech" in ProviderCatalog.known_capabilities()

    for {name, profile} <- profiles do
      capabilities = Map.fetch!(profile, "capabilities")

      assert capabilities != []

      assert MapSet.subset?(MapSet.new(capabilities), known_capabilities),
             "#{name} declares an unknown capability"

      assert is_map(Map.get(profile, "media", %{}))
    end

    for {name, profile} <- profiles,
        name not in ["voice_stt_fake", "voice_tts_fake"] do
      assert "text_generation" in profile["capabilities"]
    end
  end

  test "fake voice profiles are descriptive settings defaults, not Jido text aliases" do
    profiles = ProviderCatalog.model_profiles()
    stt = profiles["voice_stt_fake"]
    tts = profiles["voice_tts_fake"]

    assert stt["capabilities"] == ["speech_to_text"]
    assert stt["media"]["input_modalities"] == ["audio"]
    assert stt["media"]["output_modalities"] == ["text"]
    assert stt["media"]["deployment_mode"] == "fake"

    assert tts["capabilities"] == ["text_to_speech"]
    assert tts["media"]["input_modalities"] == ["text"]
    assert tts["media"]["output_modalities"] == ["audio"]
    assert tts["media"]["deployment_mode"] == "fake"

    aliases = ProviderCatalog.jido_model_aliases()
    refute Map.has_key?(aliases, :voice_stt_fake)
    refute Map.has_key?(aliases, :voice_tts_fake)
  end

  test "capability and media validators reject unknown authority-shaped metadata" do
    assert {:error, {:unknown_capability, ["shell_execute"]}} =
             ProviderCatalog.validate_capabilities(["text_generation", "shell_execute"])

    assert {:error, {:unknown_media_field, "permission"}} =
             ProviderCatalog.validate_media(%{"permission" => "allowed"})

    assert {:error, {:invalid_deployment_mode, "auto_granted"}} =
             ProviderCatalog.validate_media(%{"deployment_mode" => "auto_granted"})
  end
end
