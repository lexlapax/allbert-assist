defmodule AllbertAssist.Runtime.Redactor do
  @moduledoc """
  Runtime-facing redaction facade.

  New runtime, app, plugin, workspace, CLI, LiveView, and future sandbox-trial
  code should use this module rather than depending directly on a subsystem
  redactor. v0.31 preserves the existing `AllbertAssist.Security.Redactor`
  policy exactly.
  """

  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Security.Redactor, as: SecurityRedactor

  @type surface ::
          :signals
          | :traces
          | :audits
          | :cli
          | :live_view
          | :logs
          | :tests
          | :resource_access
          | :voice
          | :stocksage
          | :sandbox_trial

  @audio_metadata_keys ~w[
    audio_format
    byte_size
    channel_count
    cost
    duration_ms
    input_resource_uri
    mime_type
    model
    output_format
    output_resource_uri
    provider
    provider_profile
    redaction_status
    resource_uri
    sample_rate_hz
    source_resource_uri
    transcript_sha256
    usage
  ]
  @audio_path_redaction "[REDACTED_AUDIO_PATH]"
  @audio_uri_redaction "[REDACTED_AUDIO_URI]"

  @doc "Recursively redact sensitive keys, secret refs, structs, maps, and lists."
  @spec redact(term()) :: term()
  defdelegate redact(value), to: SecurityRedactor

  @doc """
  Redact a value for a named runtime surface.

  v0.31 keeps one policy for all surfaces. The surface argument exists so
  downstream code can document where a redaction boundary is applied without
  introducing local redaction forks.
  """
  @spec redact(term(), surface()) :: term()
  def redact(value, _surface), do: redact(value)

  @doc """
  Return a strict, redacted allow-list of audio metadata.

  Raw audio bytes, transcripts, local paths, provider payloads, and arbitrary
  adapter fields are intentionally dropped. Resource URIs are reduced to
  non-sensitive resource identity only.
  """
  @spec redact_audio_metadata(term()) :: term()
  def redact_audio_metadata(%{} = metadata) do
    Map.new(metadata, fn {key, value} -> {key, value} end)
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      normalized_key = key |> to_string() |> String.downcase()

      if normalized_key in @audio_metadata_keys do
        Map.put(acc, key, redact_audio_metadata_value(normalized_key, value))
      else
        acc
      end
    end)
  end

  def redact_audio_metadata(value), do: redact(value, :voice)

  @doc "Redact an audio resource URI or local audio path for traces and audits."
  @spec redact_audio_resource_uri(term()) :: String.t() | nil
  def redact_audio_resource_uri(nil), do: nil

  def redact_audio_resource_uri(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" ->
        @audio_uri_redaction

      String.starts_with?(value, "mic://") ->
        case ResourceURI.normalize(value) do
          {:ok, "mic://capture/" <> _rest = resource_uri} -> resource_uri
          _error -> @audio_uri_redaction
        end

      String.starts_with?(value, "file://") ->
        "file://#{@audio_path_redaction}"

      uri_scheme?(value) ->
        @audio_uri_redaction

      path_like?(value) ->
        @audio_path_redaction

      true ->
        @audio_uri_redaction
    end
  end

  def redact_audio_resource_uri(_value), do: @audio_uri_redaction

  @doc "Return true if a key name should cause value redaction."
  @spec sensitive_key?(term()) :: boolean()
  defdelegate sensitive_key?(key), to: SecurityRedactor

  @doc "Return a short posture summary suitable for operator status."
  @spec posture() :: SecurityRedactor.posture()
  defdelegate posture(), to: SecurityRedactor

  defp redact_audio_metadata_value(key, value)
       when key in [
              "input_resource_uri",
              "output_resource_uri",
              "resource_uri",
              "source_resource_uri"
            ],
       do: redact_audio_resource_uri(value)

  defp redact_audio_metadata_value(key, value) when key in ["cost", "usage"],
    do: redact(value, :voice)

  defp redact_audio_metadata_value(_key, value), do: redact(value, :voice)

  defp uri_scheme?(value) do
    case URI.parse(value) do
      %URI{scheme: scheme} when is_binary(scheme) -> true
      _uri -> false
    end
  rescue
    _exception -> false
  end

  defp path_like?(value) do
    String.starts_with?(value, "/") or
      String.starts_with?(value, "~/") or
      String.contains?(value, "\\") or
      String.contains?(value, "/")
  end
end
