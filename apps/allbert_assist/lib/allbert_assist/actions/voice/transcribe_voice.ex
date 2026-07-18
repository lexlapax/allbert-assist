defmodule AllbertAssist.Actions.Voice.TranscribeVoice do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :voice_transcribe,
    exposure: :internal,
    execution_mode: :voice_provider_call,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
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

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Maps
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Voice.ProviderAdapter
  alias AllbertAssist.Voice.Transcode

  @permission :voice_transcribe
  @action_name "transcribe_voice"
  @accepted_audio_extensions ~w[.wav .mp3 .m4a .ogg .webm .flac]

  @impl true
  def run(params, context) do
    with {:ok, audio_file} <- audio_file(params),
         {:ok, resolutions} <- Models.candidates_for(:speech_to_text, context) do
      run_allowed(audio_file, resolutions, context, params)
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp run_allowed(audio_file, resolutions, context, params) do
    with :ok <- voice_enabled?(),
         {:ok, audio} <- validate_audio_file(audio_file, params),
         {:ok, settings} <- voice_settings() do
      attempt_transcription(resolutions, audio, settings, context, [])
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp attempt_transcription([resolution | rest], audio, settings, context, attempts) do
    permission_decision =
      PermissionGate.authorize(@permission, voice_context(context, resolution.profile))

    cond do
      permission_decision.decision == :denied ->
        {:ok,
         stopped(permission_decision, :permission_denied, %{
           adapter_attempts: Enum.reverse(attempts)
         })}

      PermissionGate.allowed?(permission_decision) or approved_resume?(context) ->
        attempt_allowed_transcription(
          resolution,
          rest,
          audio,
          settings,
          context,
          attempts,
          permission_decision
        )

      permission_decision.decision == :needs_confirmation ->
        create_confirmation(audio, resolution, attempts, context, permission_decision)

      true ->
        {:ok,
         stopped(permission_decision, :permission_denied, %{
           adapter_attempts: Enum.reverse(attempts)
         })}
    end
  end

  defp attempt_transcription([], _audio, _settings, _context, attempts),
    do:
      {:ok,
       failed(:voice_provider_candidates_exhausted, nil, %{
         adapter_attempts: Enum.reverse(attempts)
       })}

  defp attempt_allowed_transcription(
         resolution,
         rest,
         audio,
         settings,
         context,
         attempts,
         permission_decision
       ) do
    with {:ok, transcode_spec} <-
           Transcode.build_spec(audio.path, resolution.profile, settings: settings),
         {:ok, transcript_packet} <-
           ProviderAdapter.transcribe(
             resolution.profile,
             %{
               input_path: audio.path,
               transcode_spec: transcode_spec
             },
             adapter_opts(context)
           ),
         {:ok, metadata} <-
           voice_metadata(audio, resolution, transcode_spec, transcript_packet, attempts) do
      {:ok, completed(transcript_packet.transcript, permission_decision, metadata)}
    else
      {:error, reason} ->
        attempts = [attempt_record(resolution, reason) | attempts]

        if retryable_provider_error?(reason) and rest != [] do
          attempt_transcription(rest, audio, settings, context, attempts)
        else
          {:ok,
           failed(reason, permission_decision, %{
             adapter_attempts: Enum.reverse(attempts)
           })}
        end
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
      name: @action_name,
      status: status,
      permission: @permission,
      permission_decision: permission_decision,
      voice_metadata:
        metadata |> Map.get(:voice_metadata, metadata) |> Redactor.redact_audio_metadata()
    }
  end

  defp create_confirmation(audio, resolution, attempts, context, permission_decision) do
    summary = confirmation_summary(audio, resolution, attempts)

    attrs = %{
      origin: Origin.from_context(context, @action_name),
      target_action: %{name: @action_name, module: inspect(__MODULE__)},
      target_permission: @permission,
      target_execution_mode: :voice_provider_call,
      security_decision: permission_decision,
      source_signal_id: source_signal_id(context),
      source_trace_id: source_trace_id(context),
      runner_metadata: runner_metadata(context, resolution),
      params_summary: summary,
      resume_params_ref: %{
        audio_file: audio.path,
        resource_uri: audio.resource_uri
      }
    }

    case Confirmations.create(attrs) do
      {:ok, confirmation} ->
        confirmation_id = confirmation_id(confirmation)

        {:ok,
         %{
           message: "Voice transcription needs confirmation.",
           status: :needs_confirmation,
           error: :permission_denied,
           voice_metadata: summary,
           permission_decision: permission_decision,
           confirmation: Confirmations.redact_for_output(confirmation),
           confirmation_id: confirmation_id,
           actions: [
             action(:needs_confirmation, permission_decision, %{
               provider_profile: resolution.profile_name,
               confirmation_id: confirmation_id,
               voice_metadata: summary
             })
             |> Map.put(:confirmation_metadata, confirmation_metadata(confirmation))
           ]
         }}

      {:error, reason} ->
        {:ok, failed(reason, permission_decision, %{adapter_attempts: Enum.reverse(attempts)})}
    end
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

  defp voice_metadata(audio, resolution, transcode_spec, transcript_packet, attempts) do
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
      |> maybe_put_attempts(attempts)

    {:ok, metadata}
  end

  defp attempt_record(resolution, reason) do
    %{
      provider_profile: resolution.profile_name,
      provider: Map.get(resolution.profile, :provider),
      model: Map.get(resolution.profile, :model),
      error: Redactor.redact(reason)
    }
  end

  defp maybe_put_attempts(metadata, []), do: metadata

  defp maybe_put_attempts(metadata, attempts),
    do: Map.put(metadata, :fallback_attempts, Enum.reverse(attempts))

  defp confirmation_summary(audio, resolution, attempts) do
    %{
      resource_uri: audio.resource_uri,
      provider_profile: resolution.profile_name,
      provider: Map.get(resolution.profile, :provider),
      model: Map.get(resolution.profile, :model),
      byte_size: File.stat!(audio.path).size,
      redaction_status: "redacted"
    }
    |> Redactor.redact_audio_metadata()
    |> maybe_put_confirmation_attempts(attempts)
  end

  defp maybe_put_confirmation_attempts(metadata, []), do: metadata

  defp maybe_put_confirmation_attempts(metadata, attempts) do
    Map.put(metadata, :fallback_attempts, attempts |> Enum.reverse() |> Enum.map(&safe_attempt/1))
  end

  defp safe_attempt(%{} = attempt) do
    Map.update(attempt, :error, nil, &inspect/1)
  end

  defp retryable_provider_error?({:voice_http_error, status})
       when status >= 500 and status <= 599,
       do: true

  defp retryable_provider_error?({:voice_transport_error, _reason}), do: true
  defp retryable_provider_error?(:voice_transcode_unavailable), do: false
  defp retryable_provider_error?(_reason), do: false

  defp adapter_opts(context) do
    context
    |> field(:voice_adapter_opts)
    |> normalize_keyword()
    |> maybe_put_keyword(:req_options, field(context, :req_options))
    |> maybe_put_keyword(:transcode_runner, field(context, :transcode_runner))
  end

  defp normalize_keyword(value) when is_list(value), do: value
  defp normalize_keyword(_value), do: []

  defp maybe_put_keyword(opts, _key, nil), do: opts
  defp maybe_put_keyword(opts, key, value), do: Keyword.put(opts, key, value)

  defp voice_context(context, profile) do
    context
    |> Map.drop([:voice_adapter_opts, "voice_adapter_opts", :req_options, "req_options"])
    |> Map.drop([:transcode_runner, "transcode_runner"])
    |> Map.merge(%{
      model_profile: profile,
      provider_deployment_mode: deployment_mode(profile)
    })
  end

  defp deployment_mode(%{media: %{} = media}) do
    Map.get(media, "deployment_mode") || Map.get(media, :deployment_mode)
  end

  defp deployment_mode(_profile), do: nil

  defp approved_resume?(%{confirmation: %{approved?: true}}), do: true
  defp approved_resume?(%{"confirmation" => %{"approved?" => true}}), do: true
  defp approved_resume?(_context), do: false

  defp source_signal_id(context),
    do: field(context, :input_signal_id) || field(context, :source_signal_id)

  defp source_trace_id(context), do: field(context, :trace_id) || field(context, :source_trace_id)

  defp runner_metadata(context, resolution) do
    context
    |> Map.take([:actor, :user_id, :operator_id, :channel, :surface, :response_target])
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
    |> Map.put(:selected_action, @action_name)
    |> Map.put(:provider_profile, resolution.profile_name)
  end

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(%{id: id}), do: id

  defp confirmation_metadata(confirmation) do
    %{
      id: confirmation_id(confirmation),
      status: field(confirmation, :status),
      target_action: get_in(confirmation, ["target_action", "name"]) || @action_name
    }
  end

  defp failed_status(:voice_disabled), do: :denied
  defp failed_status(:audio_file_not_found), do: :denied
  defp failed_status({:unsupported_audio_file_type, _extension}), do: :denied
  defp failed_status({:audio_input_too_large, _size, _max}), do: :denied
  defp failed_status({:audio_input_too_long, _duration, _max}), do: :denied
  defp failed_status({:voice_adapter_unavailable, _mode}), do: :error
  defp failed_status(_reason), do: :error

  defp field(map, key), do: Maps.field_truthy(map, key)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
