defmodule AllbertAssist.Settings.FragmentOwners.Voice do
  @moduledoc false
  @behaviour AllbertAssist.Settings.FragmentOwner
  alias AllbertAssist.Settings.Fragment

  @schema %{
    "voice.audio.max_bytes" => %{
      default: 10_485_760,
      max: 104_857_600,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "voice.audio.max_duration_ms" => %{
      default: 300_000,
      max: 3_600_000,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "voice.audio.retention_enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "voice.audio.retention_root" => %{
      default: "<ALLBERT_HOME>/audio",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "voice.enabled" => %{default: false, sensitive?: false, type: :boolean, writable?: true},
    "voice.local_runtime.enabled" => %{
      default: false,
      sensitive?: false,
      type: :boolean,
      writable?: true
    },
    "voice.local_runtime.max_text_bytes" => %{
      default: 16_384,
      max: 262_144,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "voice.local_runtime.ollama_base_url" => %{
      default: "http://127.0.0.1:11434/v1",
      sensitive?: false,
      type: :loopback_http_base_url,
      writable?: true
    },
    "voice.local_runtime.ollama_stt_model" => %{
      default: "gemma4:e2b",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "voice.local_runtime.port" => %{
      default: 5050,
      max: 65_535,
      min: 1024,
      sensitive?: false,
      type: :bounded_integer,
      writable?: true
    },
    "voice.local_runtime.stt_backend" => %{
      allowed_values: ["ollama"],
      default: "ollama",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "voice.local_runtime.stt_model_alias" => %{
      default: "whisper-local",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "voice.local_runtime.tts_backend" => %{
      allowed_values: ["macos_say"],
      default: "macos_say",
      sensitive?: false,
      type: :enum,
      writable?: true
    },
    "voice.local_runtime.tts_model_alias" => %{
      default: "tts-local",
      sensitive?: false,
      type: :string,
      writable?: true
    },
    "voice.schema_version" => %{
      default: 1,
      max: 1,
      min: 1,
      sensitive?: false,
      type: :bounded_integer,
      writable?: false
    },
    "voice.trace.redact_audio" => %{
      default: true,
      sensitive?: false,
      type: :boolean,
      writable?: true
    }
  }
  @defaults %{
    "voice" => %{
      "audio" => %{
        "max_bytes" => 10_485_760,
        "max_duration_ms" => 300_000,
        "retention_enabled" => false,
        "retention_root" => "<ALLBERT_HOME>/audio"
      },
      "enabled" => false,
      "local_runtime" => %{
        "enabled" => false,
        "max_text_bytes" => 16_384,
        "ollama_base_url" => "http://127.0.0.1:11434/v1",
        "ollama_stt_model" => "gemma4:e2b",
        "port" => 5050,
        "stt_backend" => "ollama",
        "stt_model_alias" => "whisper-local",
        "tts_backend" => "macos_say",
        "tts_model_alias" => "tts-local"
      },
      "schema_version" => 1,
      "trace" => %{"redact_audio" => true}
    }
  }
  @safe_write_keys [
    "voice.enabled",
    "voice.audio.max_bytes",
    "voice.audio.max_duration_ms",
    "voice.audio.retention_enabled",
    "voice.audio.retention_root",
    "voice.trace.redact_audio",
    "voice.local_runtime.enabled",
    "voice.local_runtime.port",
    "voice.local_runtime.ollama_base_url",
    "voice.local_runtime.ollama_stt_model",
    "voice.local_runtime.stt_model_alias",
    "voice.local_runtime.tts_model_alias",
    "voice.local_runtime.stt_backend",
    "voice.local_runtime.tts_backend",
    "voice.local_runtime.max_text_bytes"
  ]
  @safe_write_rows [
    {261, "voice.enabled"},
    {262, "voice.audio.max_bytes"},
    {263, "voice.audio.max_duration_ms"},
    {264, "voice.audio.retention_enabled"},
    {265, "voice.audio.retention_root"},
    {266, "voice.trace.redact_audio"},
    {267, "voice.local_runtime.enabled"},
    {268, "voice.local_runtime.port"},
    {269, "voice.local_runtime.ollama_base_url"},
    {270, "voice.local_runtime.ollama_stt_model"},
    {271, "voice.local_runtime.stt_model_alias"},
    {272, "voice.local_runtime.tts_model_alias"},
    {273, "voice.local_runtime.stt_backend"},
    {274, "voice.local_runtime.tts_backend"},
    {275, "voice.local_runtime.max_text_bytes"}
  ]
  @impl true
  def fragment do
    Fragment.new!(%{
      id: "core:voice",
      owner: "voice",
      source: :core,
      group: "voice",
      schema: @schema,
      defaults: @defaults,
      safe_write_keys: @safe_write_keys,
      metadata: %{label: "Voice"}
    })
  end

  @impl true
  def safe_write_rows, do: @safe_write_rows
end
