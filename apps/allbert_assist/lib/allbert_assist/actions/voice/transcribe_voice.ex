defmodule AllbertAssist.Actions.Voice.TranscribeVoice do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :voice_transcribe,
    exposure: :internal,
    execution_mode: :voice_provider_call,
    skill_backed?: false,
    confirmation: :required,
    name: "transcribe_voice",
    description: "Transcribe a bounded local audio file through a voice-capable profile.",
    category: "voice",
    tags: ["voice", "speech_to_text", "audio", "internal"],
    schema: [
      audio_file: [type: :string, required: true],
      resource_uri: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Voice.ProviderAdapter
  alias AllbertAssist.Voice.Transcode

  @accepted_audio_extensions ~w[.wav .mp3 .m4a .ogg .webm .flac]

  @impl true
  def run(params, context) do
    with {:ok, audio_file} <- audio_file(params),
         {:ok, resolution} <- Models.for(:speech_to_text, context) do
      permission_decision =
        PermissionGate.authorize(:voice_transcribe, voice_context(context, resolution.profile))

      if PermissionGate.allowed?(permission_decision) do
        run_allowed(audio_file, resolution, permission_decision, params)
      else
        {:ok, stopped(permission_decision, :permission_denied, %{})}
      end
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp run_allowed(audio_file, resolution, permission_decision, params) do
    with :ok <- voice_enabled?(),
         {:ok, audio} <- validate_audio_file(audio_file, params),
         {:ok, settings} <- voice_settings(),
         {:ok, transcode_spec} <-
           Transcode.build_spec(audio.path, resolution.profile, settings: settings),
         {:ok, transcript_packet} <-
           ProviderAdapter.transcribe(resolution.profile, %{
             input_path: audio.path,
             transcode_spec: transcode_spec
           }),
         {:ok, metadata} <- voice_metadata(audio, resolution, transcode_spec, transcript_packet) do
      {:ok, completed(transcript_packet.transcript, permission_decision, metadata)}
    else
      {:error, reason} ->
        {:ok, failed(reason, permission_decision, %{})}
    end
  end

  defp completed(transcript, permission_decision, metadata) do
    %{
      message: "Voice input transcribed with #{metadata.provider_profile}.",
      status: :completed,
      transcript: transcript,
      voice_metadata: metadata,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          transcript_sha256: metadata.transcript_sha256,
          provider_profile: metadata.provider_profile,
          voice_metadata: metadata
        })
      ]
    }
  end

  defp stopped(permission_decision, reason, metadata) do
    %{
      message: permission_decision.reason,
      status: PermissionGate.response_status(permission_decision),
      error: reason,
      voice_metadata: metadata,
      permission_decision: permission_decision,
      actions: [
        action(PermissionGate.response_status(permission_decision), permission_decision, metadata)
      ]
    }
  end

  defp failed(reason, permission_decision, metadata) do
    %{
      message: "Voice transcription failed: #{inspect(Redactor.redact(reason))}",
      status: failed_status(reason),
      error: Redactor.redact(reason),
      voice_metadata: metadata,
      permission_decision: permission_decision,
      actions: [
        action(failed_status(reason), permission_decision, Map.put(metadata, :error, reason))
      ]
    }
  end

  defp action(status, permission_decision, metadata) do
    %{
      name: "transcribe_voice",
      status: status,
      permission: :voice_transcribe,
      permission_decision: permission_decision,
      voice_metadata:
        metadata |> Map.get(:voice_metadata, metadata) |> Redactor.redact_audio_metadata()
    }
  end

  defp audio_file(params) do
    value = field(params, :audio_file) || field(params, :file) || field(params, :path)

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_audio_file}, else: {:ok, value}

      _value ->
        {:error, :missing_audio_file}
    end
  end

  defp voice_enabled? do
    case Settings.get("voice.enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :voice_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp validate_audio_file(audio_file, params) do
    with {:ok, resource_uri} <- ResourceURI.file(audio_file),
         {:ok, path} <- ResourceURI.path_from_file_uri(resource_uri),
         :ok <- regular_file?(path),
         :ok <- accepted_audio_extension?(path),
         {:ok, identity_uri} <- audio_resource_identity(params, resource_uri) do
      {:ok, %{path: path, resource_uri: identity_uri}}
    end
  end

  defp audio_resource_identity(params, fallback_uri) do
    case field(params, :resource_uri) do
      value when is_binary(value) ->
        case ResourceURI.normalize(value) do
          {:ok, "mic://capture/" <> _rest = uri} -> {:ok, uri}
          {:ok, "file://" <> _rest = uri} -> {:ok, uri}
          {:ok, _uri} -> {:error, :unsupported_audio_resource_uri}
          {:error, reason} -> {:error, reason}
        end

      _value ->
        {:ok, fallback_uri}
    end
  end

  defp regular_file?(path) do
    if File.regular?(path), do: :ok, else: {:error, :audio_file_not_found}
  end

  defp accepted_audio_extension?(path) do
    extension = path |> Path.extname() |> String.downcase()

    if extension in @accepted_audio_extensions do
      :ok
    else
      {:error, {:unsupported_audio_file_type, extension}}
    end
  end

  defp voice_settings do
    with {:ok, max_bytes} <- Settings.get("voice.audio.max_bytes"),
         {:ok, max_duration_ms} <- Settings.get("voice.audio.max_duration_ms") do
      {:ok,
       %{
         "voice" => %{
           "audio" => %{
             "max_bytes" => max_bytes,
             "max_duration_ms" => max_duration_ms
           }
         }
       }}
    end
  end

  defp voice_metadata(audio, resolution, transcode_spec, transcript_packet) do
    metadata =
      Redactor.redact_audio_metadata(%{
        resource_uri: audio.resource_uri,
        byte_size: transcode_spec.input_size_bytes,
        provider_profile: resolution.profile_name,
        provider: Map.get(resolution.profile, :provider),
        model: Map.get(resolution.profile, :model),
        audio_format: transcode_spec.output_format,
        duration_ms: Map.get(transcript_packet, :duration_ms),
        usage: Map.get(transcript_packet, :usage, %{source: :unavailable}),
        cost: Map.get(transcript_packet, :cost, %{source: :unavailable}),
        transcript_sha256: sha256(transcript_packet.transcript),
        redaction_status: "redacted"
      })

    {:ok, metadata}
  end

  defp voice_context(context, profile) do
    Map.merge(context, %{
      model_profile: profile,
      provider_deployment_mode: deployment_mode(profile)
    })
  end

  defp deployment_mode(%{media: %{} = media}) do
    Map.get(media, "deployment_mode") || Map.get(media, :deployment_mode)
  end

  defp deployment_mode(_profile), do: nil

  defp failed_status(:voice_disabled), do: :denied
  defp failed_status(:audio_file_not_found), do: :denied
  defp failed_status({:unsupported_audio_file_type, _extension}), do: :denied
  defp failed_status({:audio_input_too_large, _size, _max}), do: :denied
  defp failed_status({:audio_input_too_long, _duration, _max}), do: :denied
  defp failed_status({:voice_adapter_unavailable, _mode}), do: :error
  defp failed_status(_reason), do: :error

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
