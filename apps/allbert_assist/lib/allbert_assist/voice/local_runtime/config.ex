defmodule AllbertAssist.Voice.LocalRuntime.Config do
  @moduledoc """
  Configuration for the Allbert-owned local voice runtime endpoint.

  The runtime is a loopback-only product endpoint. User-configurable backend
  values are limited to local backend locations/models and are validated before
  use; they do not grant network or provider authority.
  """

  alias AllbertAssist.Settings
  alias AllbertAssist.Voice.LocalRuntime.Backends

  @default_port 5050
  @default_ollama_base_url "http://127.0.0.1:11434/v1"
  @default_stt_alias "whisper-local"
  @default_tts_alias "tts-local"
  @default_ollama_stt_model "gemma3n:e2b"
  @default_timeout_ms 30_000
  @default_max_audio_bytes 10_485_760
  @default_max_text_bytes 16_384
  @loopback_hosts ~w[localhost localhost.localdomain 127.0.0.1 ::1]

  @type t :: %{
          required(:enabled?) => boolean(),
          required(:port) => pos_integer(),
          required(:ip) => :loopback,
          required(:base_url) => String.t(),
          required(:ollama_base_url) => String.t(),
          required(:ollama_stt_model) => String.t(),
          required(:stt_model_alias) => String.t(),
          required(:tts_model_alias) => String.t(),
          required(:stt_backend) => module(),
          required(:tts_backend) => module(),
          required(:say_executable) => String.t() | nil,
          required(:ffmpeg_executable) => String.t() | nil,
          required(:timeout_ms) => pos_integer(),
          required(:max_audio_bytes) => pos_integer(),
          required(:max_text_bytes) => pos_integer(),
          required(:req_options) => keyword()
        }

  @spec build(keyword() | map()) :: t()
  def build(opts \\ []) do
    opts = normalize_opts(opts)

    port =
      positive_integer(value(opts, :port, setting("voice.local_runtime.port", @default_port)))

    %{
      enabled?:
        boolean_value(value(opts, :enabled?, setting("voice.local_runtime.enabled", false))),
      port: port,
      ip: :loopback,
      base_url: "http://127.0.0.1:#{port}/v1",
      ollama_base_url:
        value(
          opts,
          :ollama_base_url,
          setting("voice.local_runtime.ollama_base_url", @default_ollama_base_url)
        )
        |> validate_loopback_base_url!(),
      ollama_stt_model:
        string_value(
          opts,
          :ollama_stt_model,
          setting("voice.local_runtime.ollama_stt_model", @default_ollama_stt_model)
        ),
      stt_model_alias:
        string_value(
          opts,
          :stt_model_alias,
          setting("voice.local_runtime.stt_model_alias", @default_stt_alias)
        ),
      tts_model_alias:
        string_value(
          opts,
          :tts_model_alias,
          setting("voice.local_runtime.tts_model_alias", @default_tts_alias)
        ),
      stt_backend:
        backend_module(
          :stt,
          value(opts, :stt_backend, setting("voice.local_runtime.stt_backend", "ollama"))
        ),
      tts_backend:
        backend_module(
          :tts,
          value(opts, :tts_backend, setting("voice.local_runtime.tts_backend", "macos_say"))
        ),
      say_executable: string_value(opts, :say_executable, System.find_executable("say")),
      ffmpeg_executable: string_value(opts, :ffmpeg_executable, System.find_executable("ffmpeg")),
      timeout_ms: positive_integer(value(opts, :timeout_ms, @default_timeout_ms)),
      max_audio_bytes:
        positive_integer(
          value(
            opts,
            :max_audio_bytes,
            setting("voice.audio.max_bytes", @default_max_audio_bytes)
          )
        ),
      max_text_bytes:
        positive_integer(
          value(
            opts,
            :max_text_bytes,
            setting("voice.local_runtime.max_text_bytes", @default_max_text_bytes)
          )
        ),
      req_options: Keyword.get(opts, :req_options, [])
    }
  end

  @spec validate_loopback_base_url!(String.t()) :: String.t()
  def validate_loopback_base_url!(base_url) when is_binary(base_url) do
    uri = URI.parse(String.trim(base_url))

    cond do
      uri.scheme not in ["http", "https"] ->
        raise ArgumentError, "local voice backend URL must use http or https"

      not is_binary(uri.host) or uri.host == "" ->
        raise ArgumentError, "local voice backend URL must include a host"

      is_binary(uri.userinfo) and uri.userinfo != "" ->
        raise ArgumentError, "local voice backend URL must not contain credentials"

      is_binary(uri.query) and uri.query != "" ->
        raise ArgumentError, "local voice backend URL must not contain a query string"

      is_binary(uri.fragment) and uri.fragment != "" ->
        raise ArgumentError, "local voice backend URL must not contain a fragment"

      not loopback_host?(uri.host) ->
        raise ArgumentError, "local voice backend URL must point to loopback"

      true ->
        base_url |> String.trim() |> String.trim_trailing("/")
    end
  end

  defp normalize_opts(opts) when is_map(opts), do: Map.to_list(opts)

  defp normalize_opts(opts) when is_list(opts), do: opts

  defp value(opts, key, default), do: Keyword.get(opts, key, default)

  defp string_value(opts, key, default) do
    case value(opts, key, default) do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: nil, else: value

      value ->
        value
    end
  end

  defp positive_integer(value) when is_integer(value) and value > 0, do: value

  defp positive_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} when integer > 0 -> integer
      _parse -> raise ArgumentError, "expected a positive integer, got #{inspect(value)}"
    end
  end

  defp positive_integer(value),
    do: raise(ArgumentError, "expected a positive integer, got #{inspect(value)}")

  defp boolean_value(value) when is_boolean(value), do: value
  defp boolean_value("true"), do: true
  defp boolean_value("false"), do: false
  defp boolean_value(value), do: raise(ArgumentError, "expected a boolean, got #{inspect(value)}")

  defp backend_module(_kind, module) when is_atom(module), do: module
  defp backend_module(:stt, "ollama"), do: Backends.OllamaSTT
  defp backend_module(:tts, "macos_say"), do: Backends.MacOSSayTTS

  defp backend_module(kind, value),
    do: raise(ArgumentError, "unsupported local voice #{kind} backend #{inspect(value)}")

  defp setting(key, default) do
    case Settings.get(key) do
      {:ok, value} -> value
      {:error, _reason} -> default
    end
  rescue
    _exception -> default
  end

  defp loopback_host?(host) when host in @loopback_hosts, do: true

  defp loopback_host?(host) do
    case :inet.parse_address(String.to_charlist(host)) do
      {:ok, {127, _b, _c, _d}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _result -> false
    end
  end
end
