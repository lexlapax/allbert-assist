defmodule AllbertAssist.Actions.Voice.SynthesizeVoice do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :voice_synthesize,
    exposure: :agent,
    execution_mode: :voice_provider_call,
    skill_backed?: false,
    confirmation: :required,
    resumable?: true,
    name: "synthesize_voice",
    description: "Synthesize bounded text into an audio file through a voice-capable profile.",
    category: "voice",
    tags: ["voice", "text_to_speech", "audio", "text_to_audio"],
    schema: [
      text: [type: :string, required: true],
      output_format: [type: :string, required: false],
      voice: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.Origin
  alias AllbertAssist.Maps
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models
  alias AllbertAssist.Voice.ProviderAdapter

  @permission :voice_synthesize
  @action_name "synthesize_voice"
  @default_format "wav"

  @impl true
  def run(params, context) do
    with {:ok, text} <- text(params),
         {:ok, resolutions} <- Models.candidates_for(:text_to_speech, context) do
      run_allowed(text, resolutions, context, params)
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp run_allowed(text, resolutions, context, params) do
    with :ok <- voice_enabled?() do
      attempt_synthesis(resolutions, text, context, params, [])
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp attempt_synthesis([resolution | rest], text, context, params, attempts) do
    permission_decision =
      PermissionGate.authorize(@permission, voice_context(context, resolution.profile))

    cond do
      permission_decision.decision == :denied ->
        {:ok,
         stopped(permission_decision, :permission_denied, %{
           adapter_attempts: Enum.reverse(attempts)
         })}

      PermissionGate.allowed?(permission_decision) or approved_resume?(context) ->
        attempt_allowed_synthesis(
          resolution,
          rest,
          text,
          context,
          params,
          attempts,
          permission_decision
        )

      permission_decision.decision == :needs_confirmation ->
        create_confirmation(text, resolution, params, attempts, context, permission_decision)

      true ->
        {:ok,
         stopped(permission_decision, :permission_denied, %{
           adapter_attempts: Enum.reverse(attempts)
         })}
    end
  end

  defp attempt_synthesis([], _text, _context, _params, attempts),
    do:
      {:ok,
       failed(:voice_provider_candidates_exhausted, nil, %{
         adapter_attempts: Enum.reverse(attempts)
       })}

  defp attempt_allowed_synthesis(
         resolution,
         rest,
         text,
         context,
         params,
         attempts,
         permission_decision
       ) do
    with {:ok, output_format} <- output_format(resolution.profile, params),
         {:ok, audio} <-
           ProviderAdapter.synthesize(
             resolution.profile,
             %{
               text: text,
               output_format: output_format,
               voice: field(params, :voice)
             },
             adapter_opts(context)
           ),
         {:ok, metadata} <- voice_metadata(audio, resolution, attempts) do
      {:ok, completed(audio, permission_decision, metadata)}
    else
      {:error, reason} ->
        attempts = [attempt_record(resolution, reason) | attempts]

        if retryable_provider_error?(reason) and rest != [] do
          attempt_synthesis(rest, text, context, params, attempts)
        else
          {:ok,
           failed(reason, permission_decision, %{
             adapter_attempts: Enum.reverse(attempts)
           })}
        end
    end
  end

  defp completed(audio, permission_decision, metadata) do
    %{
      message: "Voice output synthesized with #{metadata.provider_profile}.",
      status: :completed,
      audio_file: audio.path,
      output_resource_uri: metadata.output_resource_uri,
      voice_metadata: metadata,
      permission_decision: permission_decision,
      actions: [
        action(:completed, permission_decision, %{
          provider_profile: metadata.provider_profile,
          output_resource_uri: metadata.output_resource_uri,
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
      message: "Voice synthesis failed: #{inspect(Redactor.redact(reason))}",
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

  defp create_confirmation(text, resolution, params, attempts, context, permission_decision) do
    with {:ok, output_format} <- output_format(resolution.profile, params) do
      summary = confirmation_summary(text, resolution, output_format, params, attempts)

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
          text: text,
          output_format: output_format,
          voice: field(params, :voice)
        }
      }

      case Confirmations.create(attrs) do
        {:ok, confirmation} ->
          confirmation_id = confirmation_id(confirmation)

          {:ok,
           %{
             message: "Voice synthesis needs confirmation.",
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
    else
      {:error, reason} ->
        {:ok, failed(reason, permission_decision, %{adapter_attempts: Enum.reverse(attempts)})}
    end
  end

  defp text(params) do
    value = field(params, :text) || field(params, :input) || field(params, :prompt)

    case value do
      value when is_binary(value) ->
        value = String.trim(value)
        if value == "", do: {:error, :missing_text}, else: {:ok, value}

      _value ->
        {:error, :missing_text}
    end
  end

  defp voice_enabled? do
    case Settings.get("voice.enabled") do
      {:ok, true} -> :ok
      {:ok, false} -> {:error, :voice_disabled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp output_format(profile, params) do
    requested =
      params
      |> field(:output_format)
      |> normalize_format()

    supported =
      profile
      |> media_field("audio_formats_supported")
      |> normalize_formats()

    cond do
      supported == [] ->
        {:error, :missing_supported_audio_formats}

      is_binary(requested) and requested in supported ->
        {:ok, requested}

      is_binary(requested) ->
        {:error, {:unsupported_audio_output_format, requested, supported}}

      @default_format in supported ->
        {:ok, @default_format}

      true ->
        {:ok, hd(supported)}
    end
  end

  defp voice_metadata(audio, resolution, attempts) do
    metadata =
      Redactor.redact_audio_metadata(%{
        output_resource_uri: audio.resource_uri,
        byte_size: audio.byte_size,
        provider_profile: resolution.profile_name,
        provider: Map.get(resolution.profile, :provider),
        model: Map.get(resolution.profile, :model),
        output_format: audio.output_format,
        mime_type: audio.mime_type,
        duration_ms: Map.get(audio, :duration_ms),
        sample_rate_hz: Map.get(audio, :sample_rate_hz),
        channel_count: Map.get(audio, :channel_count),
        usage: Map.get(audio, :usage, %{source: :unavailable}),
        cost: Map.get(audio, :cost, %{source: :unavailable}),
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

  defp confirmation_summary(text, resolution, output_format, params, attempts) do
    %{
      provider_profile: resolution.profile_name,
      provider: Map.get(resolution.profile, :provider),
      model: Map.get(resolution.profile, :model),
      output_format: output_format,
      byte_size: byte_size(text),
      transcript_sha256: sha256(text),
      redaction_status: "redacted"
    }
    |> maybe_put_voice(field(params, :voice))
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
  defp retryable_provider_error?(_reason), do: false

  defp adapter_opts(context) do
    context
    |> field(:voice_adapter_opts)
    |> normalize_keyword()
    |> maybe_put_keyword(:req_options, field(context, :req_options))
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

  defp maybe_put_voice(summary, nil), do: summary
  defp maybe_put_voice(summary, ""), do: summary
  defp maybe_put_voice(summary, voice), do: Map.put(summary, :voice, voice)

  defp confirmation_id(%{"id" => id}), do: id
  defp confirmation_id(%{id: id}), do: id

  defp confirmation_metadata(confirmation) do
    %{
      id: confirmation_id(confirmation),
      status: field(confirmation, :status),
      target_action: get_in(confirmation, ["target_action", "name"]) || @action_name
    }
  end

  defp media_field(%{media: %{} = media}, key),
    do: Map.get(media, key) || Map.get(media, String.to_atom(key))

  defp media_field(%{"media" => %{} = media}, key),
    do: Map.get(media, key) || Map.get(media, String.to_atom(key))

  defp media_field(_profile, _key), do: nil

  defp normalize_formats(formats) when is_list(formats) do
    formats
    |> Enum.map(&normalize_format/1)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp normalize_formats(_formats), do: []

  defp normalize_format(value) when is_binary(value) do
    value
    |> String.trim()
    |> String.trim_leading(".")
    |> String.downcase()
    |> case do
      "" -> nil
      format -> format
    end
  end

  defp normalize_format(nil), do: nil

  defp normalize_format(value) when is_atom(value),
    do: value |> Atom.to_string() |> normalize_format()

  defp normalize_format(_value), do: nil

  defp failed_status(:voice_disabled), do: :denied
  defp failed_status(:missing_text), do: :denied
  defp failed_status({:unsupported_audio_output_format, _format, _supported}), do: :denied
  defp failed_status({:unsupported_fake_tts_format, _format}), do: :denied
  defp failed_status({:voice_adapter_unavailable, _mode}), do: :error
  defp failed_status(_reason), do: :error

  defp field(map, key), do: Maps.field_truthy(map, key)

  defp sha256(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
