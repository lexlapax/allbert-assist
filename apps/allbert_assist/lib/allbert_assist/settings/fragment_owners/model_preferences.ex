defmodule AllbertAssist.Settings.FragmentOwners.ModelPreferences do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "model_preferences.primary" => %{
      default: "local",
      sensitive?: false,
      type: :profile_ref,
      writable?: true
    },
    "model_preferences.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    }
  }
  @defaults %{
    "model_preferences" => %{
      "capabilities" => %{
        "embeddings" => ["embedding_local"],
        "image_generation" => ["image_openai", "image_gemini"],
        "speech_to_text" => ["voice_stt_local", "voice_stt_openai", "voice_stt_gemini"],
        "text_generation" => ["local", "fast"],
        "text_to_speech" => ["voice_tts_local", "voice_tts_openai", "voice_tts_gemini"],
        "vision_input" => ["vision_openai", "vision_gemini"]
      },
      "primary" => "local",
      "schema_version" => 1,
      "tasks" => %{
        "coding" => ["coding_local", "coding", "capable", "local"],
        "direct_answer" => ["direct_answer_local"],
        "fanout_manager" => ["direct_answer_local"],
        "fanout_synthesis" => ["direct_answer_local"]
      }
    }
  }
  @safe_write_keys [
    "model_preferences.primary",
    "model_preferences.tasks.*",
    "model_preferences.capabilities.*"
  ]
  @safe_write_rows [
    {64, "model_preferences.primary"},
    {65, "model_preferences.tasks.*"},
    {66, "model_preferences.capabilities.*"},
    {111, "providers.*.enabled"},
    {112, "providers.*.endpoint_kind"},
    {113, "providers.*.base_url"},
    {114, "providers.*.api_key_ref"},
    {136, "model_profiles.*.provider"},
    {137, "model_profiles.*.model"},
    {138, "model_profiles.*.aliases"},
    {139, "model_profiles.*.capabilities"},
    {140, "model_profiles.*.media"},
    {141, "model_profiles.*.temperature"},
    {142, "model_profiles.*.max_tokens"},
    {143, "model_profiles.*.timeout_ms"}
  ]

  @supplemental_safe_write_keys [
    "providers.*.enabled",
    "providers.*.endpoint_kind",
    "providers.*.base_url",
    "providers.*.api_key_ref",
    "model_profiles.*.provider",
    "model_profiles.*.model",
    "model_profiles.*.aliases",
    "model_profiles.*.capabilities",
    "model_profiles.*.media",
    "model_profiles.*.temperature",
    "model_profiles.*.max_tokens",
    "model_profiles.*.timeout_ms"
  ]

  @dynamic_default_keys [
    "model_preferences.tasks.*",
    "model_preferences.capabilities.*",
    "providers.*.type",
    "providers.*.enabled",
    "providers.*.endpoint_kind",
    "providers.*.base_url",
    "providers.*.api_key_ref",
    "model_profiles.*.provider",
    "model_profiles.*.model",
    "model_profiles.*.aliases",
    "model_profiles.*.capabilities",
    "model_profiles.*.media",
    "model_profiles.*.temperature",
    "model_profiles.*.max_tokens",
    "model_profiles.*.timeout_ms"
  ]

  @legacy_routing_profiles %{
    "model_profiles" => %{
      "embedding_local" => %{
        "provider" => "local_ollama",
        "model" => "nomic-embed-text",
        "capabilities" => ["embeddings"],
        "timeout_ms" => 30_000
      },
      "router_local" => %{
        "provider" => "local_ollama",
        "model" => "llama3.1:8b",
        "capabilities" => ["text_generation"],
        "temperature" => 0.0,
        "max_tokens" => 512,
        "timeout_ms" => 45_000
      },
      "router_escalation_local" => %{
        "provider" => "local_ollama",
        "model" => "gemma4:26b",
        "capabilities" => ["text_generation"],
        "temperature" => 0.0,
        "max_tokens" => 512,
        "timeout_ms" => 60_000
      }
    }
  }

  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:model_preferences",
      owner: "model_preferences",
      source: :core,
      group: "model_preferences",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Model Preferences"}
    })
  end

  @impl true
  def composition_defaults do
    @defaults
    |> Map.merge(@legacy_routing_profiles)
    |> AllbertAssist.Settings.ProviderCatalog.merge_defaults()
  end

  @impl true
  def dynamic_default_keys, do: @dynamic_default_keys

  @impl true
  def supplemental_safe_write_keys, do: @supplemental_safe_write_keys

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
