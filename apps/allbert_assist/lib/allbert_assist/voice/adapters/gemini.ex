defmodule AllbertAssist.Voice.Adapters.Gemini do
  @moduledoc """
  Gemini voice adapter.

  STT uses the Gemini Interactions API with inline base64 audio. TTS uses
  `models/*:generateContent` with `responseModalities: ["AUDIO"]` and writes
  the bounded returned audio as a local file.
  """

  @behaviour AllbertAssist.Voice.ProviderAdapter

  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Voice.ProviderHTTP
  alias AllbertAssist.Voice.Transcode

  @api_revision "2026-05-20"
  @default_voice "Kore"
  @default_max_audio_bytes 10_485_760
  @gemini_pcm_sample_rate_hz 24_000
  @gemini_pcm_channel_count 1
  @gemini_pcm_bits_per_sample 16

  @impl true
  def transcribe(profile, %{transcode_spec: transcode_spec}, opts) do
    with {:ok, input_path} <- Transcode.materialize(transcode_spec, opts),
         {:ok, audio} <- File.read(input_path),
         :ok <- validate_audio_size(audio, profile),
         {:ok, endpoint} <-
           ProviderHTTP.endpoint(profile, "/interactions",
             headers: [{"api-revision", @api_revision}]
           ),
         {:ok, response} <-
           ProviderHTTP.request(
             :post,
             endpoint,
             [
               json: %{
                 model: model(profile),
                 input: [
                   %{
                     type: "text",
                     text: "Transcribe this audio. Return only the transcript text."
                   },
                   %{
                     type: "audio",
                     data: Base.encode64(audio),
                     mime_type: ProviderHTTP.mime_type_for_path(input_path, "audio/wav")
                   }
                 ]
               }
             ],
             profile,
             opts
           ),
         {:ok, body} <- ProviderHTTP.json_body(response),
         {:ok, transcript} <- transcript_text(body) do
      {:ok,
       %{
         transcript: transcript,
         duration_ms: nil,
         usage: unavailable_packet(),
         cost: unavailable_packet()
       }}
    end
  end

  def transcribe(_profile, _request, _opts), do: {:error, :missing_audio_input}

  @impl true
  def synthesize(profile, %{text: text, output_format: output_format} = request, opts)
      when is_binary(text) and is_binary(output_format) do
    with {:ok, endpoint} <-
           ProviderHTTP.endpoint(profile, "/models/#{model(profile)}:generateContent"),
         {:ok, response} <-
           ProviderHTTP.request(
             :post,
             endpoint,
             [json: tts_request(profile, text, voice(request))],
             profile,
             opts
           ),
         {:ok, body} <- ProviderHTTP.json_body(response),
         {:ok, audio, mime_type} <- audio_from_body(body, output_format),
         :ok <- validate_audio_size(audio, profile),
         {:ok, packet} <- write_audio(profile, text, output_format, audio, mime_type) do
      {:ok, Map.merge(packet, %{usage: unavailable_packet(), cost: unavailable_packet()})}
    end
  end

  def synthesize(_profile, _request, _opts), do: {:error, :missing_text}

  @impl true
  def doctor(profile, opts) do
    with {:ok, endpoint} <- ProviderHTTP.endpoint(profile, "/models"),
         {:ok, response} <- ProviderHTTP.request(:get, endpoint, [], profile, opts),
         {:ok, body} <- ProviderHTTP.json_body(response) do
      {:ok,
       %{
         endpoint_ok: true,
         model_available: model_available?(body, profile),
         provider_usage_metadata_available: false,
         redacted_host: endpoint.redacted_host,
         diagnostic_codes: []
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           endpoint_ok: false,
           model_available: :unknown,
           provider_usage_metadata_available: false,
           redacted_host: ProviderHTTP.redacted_host(Map.get(profile, :provider_base_url)),
           diagnostic_codes: [diagnostic_code(reason)]
         }}
    end
  end

  defp tts_request(profile, text, voice) do
    %{
      contents: [
        %{
          parts: [
            %{
              text: text
            }
          ]
        }
      ],
      generationConfig: %{
        responseModalities: ["AUDIO"],
        speechConfig: %{
          voiceConfig: %{
            prebuiltVoiceConfig: %{
              voiceName: voice
            }
          }
        }
      },
      model: model(profile)
    }
  end

  defp transcript_text(%{"output_text" => text}) when is_binary(text), do: non_empty_text(text)

  defp transcript_text(body) do
    body
    |> text_parts()
    |> Enum.join("")
    |> non_empty_text()
  end

  defp text_parts(%{"candidates" => candidates}) when is_list(candidates) do
    candidates
    |> Enum.flat_map(fn candidate ->
      candidate
      |> get_in(["content", "parts"])
      |> case do
        parts when is_list(parts) -> parts
        _missing -> []
      end
    end)
    |> Enum.map(&Map.get(&1, "text"))
    |> Enum.filter(&is_binary/1)
  end

  defp text_parts(_body), do: []

  defp non_empty_text(text) when is_binary(text) do
    text = String.trim(text)
    if text == "", do: {:error, :empty_voice_transcript}, else: {:ok, text}
  end

  defp audio_from_body(%{"output_audio" => %{"data" => data} = audio}, output_format)
       when is_binary(data) do
    decode_audio_data(data, Map.get(audio, "mime_type"), output_format)
  end

  defp audio_from_body(body, output_format) do
    body
    |> audio_parts()
    |> List.first()
    |> case do
      %{"data" => data} = inline when is_binary(data) ->
        decode_audio_data(
          data,
          Map.get(inline, "mimeType") || Map.get(inline, "mime_type"),
          output_format
        )

      _missing ->
        {:error, :missing_voice_audio}
    end
  end

  defp audio_parts(%{"candidates" => candidates}) when is_list(candidates) do
    candidates
    |> Enum.flat_map(fn candidate ->
      candidate
      |> get_in(["content", "parts"])
      |> case do
        parts when is_list(parts) -> parts
        _missing -> []
      end
    end)
    |> Enum.map(&(Map.get(&1, "inlineData") || Map.get(&1, "inline_data")))
    |> Enum.filter(&is_map/1)
  end

  defp audio_parts(_body), do: []

  defp decode_audio_data(data, mime_type, "wav") do
    with {:ok, audio} <- Base.decode64(data) do
      if pcm_mime_type?(mime_type) do
        {:ok, pcm_to_wav(audio), "audio/wav"}
      else
        {:ok, audio, mime_type || "audio/wav"}
      end
    end
  end

  defp decode_audio_data(data, mime_type, _output_format) do
    with {:ok, audio} <- Base.decode64(data) do
      {:ok, audio, mime_type || "application/octet-stream"}
    end
  end

  defp pcm_mime_type?(nil), do: true
  defp pcm_mime_type?(mime_type) when is_binary(mime_type), do: String.contains?(mime_type, "pcm")
  defp pcm_mime_type?(_mime_type), do: false

  defp pcm_to_wav(pcm) do
    data_size = byte_size(pcm)

    byte_rate =
      @gemini_pcm_sample_rate_hz * @gemini_pcm_channel_count * div(@gemini_pcm_bits_per_sample, 8)

    block_align = @gemini_pcm_channel_count * div(@gemini_pcm_bits_per_sample, 8)

    "RIFF" <>
      <<36 + data_size::little-unsigned-integer-size(32)>> <>
      "WAVE" <>
      "fmt " <>
      <<16::little-unsigned-integer-size(32)>> <>
      <<1::little-unsigned-integer-size(16)>> <>
      <<@gemini_pcm_channel_count::little-unsigned-integer-size(16)>> <>
      <<@gemini_pcm_sample_rate_hz::little-unsigned-integer-size(32)>> <>
      <<byte_rate::little-unsigned-integer-size(32)>> <>
      <<block_align::little-unsigned-integer-size(16)>> <>
      <<@gemini_pcm_bits_per_sample::little-unsigned-integer-size(16)>> <>
      "data" <>
      <<data_size::little-unsigned-integer-size(32)>> <>
      pcm
  end

  defp validate_audio_size(audio, profile) do
    max_bytes = ProviderHTTP.max_audio_bytes(profile, @default_max_audio_bytes)

    if byte_size(audio) <= max_bytes do
      :ok
    else
      {:error, {:audio_output_too_large, byte_size(audio), max_bytes}}
    end
  end

  defp write_audio(profile, text, output_format, audio, mime_type) do
    path = output_path(profile, text, output_format)

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(path, audio),
         {:ok, resource_uri} <- ResourceURI.file(path) do
      {:ok,
       %{
         path: path,
         resource_uri: resource_uri,
         byte_size: byte_size(audio),
         output_format: output_format,
         duration_ms: nil,
         sample_rate_hz: if(output_format == "wav", do: @gemini_pcm_sample_rate_hz, else: nil),
         channel_count: if(output_format == "wav", do: @gemini_pcm_channel_count, else: nil),
         mime_type: mime_type || ProviderHTTP.output_mime_type(output_format)
       }}
    end
  end

  defp output_path(profile, text, output_format) do
    digest =
      :crypto.hash(:sha256, "#{Map.get(profile, :name)}:#{text}:#{output_format}")
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    Path.join([Paths.tmp_root(), "voice-synthesis", "voice-#{digest}.#{output_format}"])
  end

  defp model(%{model: model}) when is_binary(model), do: model
  defp model(%{"model" => model}) when is_binary(model), do: model

  defp voice(%{voice: voice}) when is_binary(voice) and voice != "", do: voice
  defp voice(%{"voice" => voice}) when is_binary(voice) and voice != "", do: voice
  defp voice(_request), do: @default_voice

  defp model_available?(body, profile) do
    model = model(profile)

    body
    |> model_entries()
    |> Enum.any?(&(normalize_model_id(model_id(&1)) == model))
  end

  defp model_entries(%{"models" => entries}) when is_list(entries), do: entries
  defp model_entries(%{"data" => entries}) when is_list(entries), do: entries
  defp model_entries(_body), do: []

  defp model_id(%{} = entry),
    do: Map.get(entry, "name") || Map.get(entry, "id") || Map.get(entry, "model")

  defp model_id(_entry), do: nil

  defp normalize_model_id("models/" <> model), do: model
  defp normalize_model_id(model), do: model

  defp diagnostic_code({:voice_http_error, _status}), do: :voice_provider_http_error
  defp diagnostic_code({:voice_transport_error, _reason}), do: :voice_provider_unreachable

  defp diagnostic_code({:voice_credential_missing, _provider}),
    do: :voice_provider_credential_missing

  defp diagnostic_code({:voice_credential_unavailable, _provider, _reason}),
    do: :voice_provider_credential_unavailable

  defp diagnostic_code(_reason), do: :voice_provider_probe_failed

  defp unavailable_packet, do: %{source: :unavailable}
end
