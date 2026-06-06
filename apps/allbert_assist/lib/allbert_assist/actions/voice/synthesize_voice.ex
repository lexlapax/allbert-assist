defmodule AllbertAssist.Actions.Voice.SynthesizeVoice do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :voice_synthesize,
    exposure: :internal,
    execution_mode: :voice_provider_call,
    skill_backed?: false,
    confirmation: :required,
    name: "synthesize_voice",
    description: "Synthesize bounded text into an audio file through a voice-capable profile.",
    category: "voice",
    tags: ["voice", "text_to_speech", "audio", "internal"],
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

  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Models

  @default_format "wav"
  @sample_rate_hz 16_000
  @duration_ms 250
  @bits_per_sample 16
  @channel_count 1

  @impl true
  def run(params, context) do
    with {:ok, text} <- text(params),
         {:ok, resolution} <- Models.for(:text_to_speech, context) do
      permission_decision =
        PermissionGate.authorize(:voice_synthesize, voice_context(context, resolution.profile))

      if PermissionGate.allowed?(permission_decision) do
        run_allowed(text, resolution, permission_decision, params)
      else
        {:ok, stopped(permission_decision, :permission_denied, %{})}
      end
    else
      {:error, reason} ->
        {:ok, failed(reason, nil, %{})}
    end
  end

  defp run_allowed(text, resolution, permission_decision, params) do
    with :ok <- voice_enabled?(),
         {:ok, output_format} <- output_format(resolution.profile, params),
         {:ok, audio} <- synthesize_with_adapter(text, resolution.profile, output_format),
         {:ok, metadata} <- voice_metadata(audio, text, resolution) do
      {:ok, completed(audio, permission_decision, metadata)}
    else
      {:error, reason} ->
        {:ok, failed(reason, permission_decision, %{})}
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
      name: "synthesize_voice",
      status: status,
      permission: :voice_synthesize,
      permission_decision: permission_decision,
      voice_metadata:
        metadata |> Map.get(:voice_metadata, metadata) |> Redactor.redact_audio_metadata()
    }
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

  defp synthesize_with_adapter(text, profile, output_format) do
    case deployment_mode(profile) do
      "fake" -> write_fake_audio(text, output_format)
      :fake -> write_fake_audio(text, output_format)
      mode -> {:error, {:voice_adapter_unavailable, mode || :unknown}}
    end
  end

  defp write_fake_audio(text, "wav") do
    audio = fake_wav(text)
    path = output_path(text, "wav")

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, audio),
         {:ok, resource_uri} <- ResourceURI.file(path) do
      {:ok,
       %{
         path: path,
         resource_uri: resource_uri,
         byte_size: byte_size(audio),
         output_format: "wav",
         duration_ms: @duration_ms,
         sample_rate_hz: @sample_rate_hz,
         channel_count: @channel_count,
         mime_type: "audio/wav"
       }}
    end
  end

  defp write_fake_audio(_text, format), do: {:error, {:unsupported_fake_tts_format, format}}

  defp fake_wav(_text) do
    sample_count = div(@sample_rate_hz * @duration_ms, 1000)
    data = :binary.copy(<<0, 0>>, sample_count)
    data_size = byte_size(data)
    byte_rate = @sample_rate_hz * @channel_count * div(@bits_per_sample, 8)
    block_align = @channel_count * div(@bits_per_sample, 8)

    "RIFF" <>
      <<36 + data_size::little-unsigned-integer-size(32)>> <>
      "WAVE" <>
      "fmt " <>
      <<16::little-unsigned-integer-size(32)>> <>
      <<1::little-unsigned-integer-size(16)>> <>
      <<@channel_count::little-unsigned-integer-size(16)>> <>
      <<@sample_rate_hz::little-unsigned-integer-size(32)>> <>
      <<byte_rate::little-unsigned-integer-size(32)>> <>
      <<block_align::little-unsigned-integer-size(16)>> <>
      <<@bits_per_sample::little-unsigned-integer-size(16)>> <>
      "data" <>
      <<data_size::little-unsigned-integer-size(32)>> <>
      data
  end

  defp output_path(text, output_format) do
    digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> binary_part(0, 16)
    Path.join([Paths.tmp_root(), "voice-synthesis", "voice-#{digest}.#{output_format}"])
  end

  defp voice_metadata(audio, text, resolution) do
    metadata =
      Redactor.redact_audio_metadata(%{
        output_resource_uri: audio.resource_uri,
        byte_size: audio.byte_size,
        provider_profile: resolution.profile_name,
        provider: Map.get(resolution.profile, :provider),
        model: Map.get(resolution.profile, :model),
        output_format: audio.output_format,
        mime_type: audio.mime_type,
        duration_ms: audio.duration_ms,
        sample_rate_hz: audio.sample_rate_hz,
        channel_count: audio.channel_count,
        usage: %{
          input_text_bytes: byte_size(text),
          output_audio_bytes: audio.byte_size,
          output_audio_duration_ms: audio.duration_ms
        },
        cost: %{amount: 0, currency: "USD", source: "fake"},
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

  defp field(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp field(_map, _key), do: nil
end
