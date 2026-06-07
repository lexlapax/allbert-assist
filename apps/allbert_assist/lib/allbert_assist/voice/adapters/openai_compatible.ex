defmodule AllbertAssist.Voice.Adapters.OpenAICompatible do
  @moduledoc """
  OpenAI-compatible request-file STT/TTS adapter.

  Local voice endpoints and OpenAI remote voice both use this request shape:
  `/v1/audio/transcriptions` for multipart STT and `/v1/audio/speech` for
  JSON TTS with a raw audio response.
  """

  @behaviour AllbertAssist.Voice.ProviderAdapter

  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Runtime.Paths
  alias AllbertAssist.Voice.ProviderHTTP
  alias AllbertAssist.Voice.Transcode

  @default_voice "alloy"
  @default_max_audio_bytes 10_485_760

  @impl true
  def transcribe(profile, %{transcode_spec: transcode_spec}, opts) do
    with {:ok, input_path} <- Transcode.materialize(transcode_spec, opts),
         {:ok, audio} <- File.read(input_path),
         {:ok, endpoint} <- ProviderHTTP.endpoint(profile, "/audio/transcriptions"),
         {:ok, response} <-
           ProviderHTTP.request(
             :post,
             endpoint,
             [
               form_multipart: [
                 file: {audio, filename: Path.basename(input_path)},
                 model: model(profile),
                 response_format: "json"
               ]
             ],
             profile,
             opts
           ),
         {:ok, body} <- ProviderHTTP.json_body(response),
         {:ok, transcript} <- transcript_text(body) do
      {:ok,
       %{
         transcript: transcript,
         duration_ms: duration_ms(body),
         usage: provider_usage(body),
         cost: unavailable_packet()
       }}
    end
  end

  def transcribe(_profile, _request, _opts), do: {:error, :missing_audio_input}

  @impl true
  def synthesize(profile, %{text: text, output_format: output_format} = request, opts)
      when is_binary(text) and is_binary(output_format) do
    with {:ok, endpoint} <- ProviderHTTP.endpoint(profile, "/audio/speech"),
         {:ok, response} <-
           ProviderHTTP.request(
             :post,
             endpoint,
             [
               json: %{
                 model: model(profile),
                 input: text,
                 voice: voice(request),
                 response_format: output_format
               }
             ],
             profile,
             opts
           ),
         {:ok, audio} <-
           ProviderHTTP.audio_body(
             response,
             ProviderHTTP.max_audio_bytes(profile, @default_max_audio_bytes)
           ),
         {:ok, packet} <- write_audio(profile, text, output_format, audio, response) do
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
         provider_usage_metadata_available: :unknown,
         local_runtime_present: local_runtime_present(profile),
         redacted_host: endpoint.redacted_host,
         diagnostic_codes: []
       }}
    else
      {:error, reason} ->
        {:ok,
         %{
           endpoint_ok: false,
           model_available: :unknown,
           provider_usage_metadata_available: :unknown,
           local_runtime_present: local_runtime_present(profile),
           redacted_host: ProviderHTTP.redacted_host(Map.get(profile, :provider_base_url)),
           diagnostic_codes: [diagnostic_code(reason)]
         }}
    end
  end

  defp transcript_text(%{"text" => text}) when is_binary(text) do
    text = String.trim(text)
    if text == "", do: {:error, :empty_voice_transcript}, else: {:ok, text}
  end

  defp transcript_text(%{"transcript" => text}) when is_binary(text),
    do: transcript_text(%{"text" => text})

  defp transcript_text(_body), do: {:error, :missing_voice_transcript}

  defp duration_ms(%{"duration" => seconds}) when is_number(seconds),
    do: round(seconds * 1000)

  defp duration_ms(%{"duration_ms" => duration_ms}) when is_integer(duration_ms),
    do: duration_ms

  defp duration_ms(_body), do: nil

  defp provider_usage(%{"usage" => usage}) when is_map(usage),
    do: Map.put_new(usage, "source", "provider")

  defp provider_usage(_body), do: unavailable_packet()

  defp write_audio(profile, text, output_format, audio, response) do
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
         mime_type:
           ProviderHTTP.content_type(response) || ProviderHTTP.output_mime_type(output_format)
       }}
    end
  end

  defp output_path(profile, text, output_format) do
    nonce = System.unique_integer([:positive, :monotonic])

    digest =
      :crypto.hash(:sha256, "#{Map.get(profile, :name)}:#{text}:#{output_format}:#{nonce}")
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
    |> Enum.any?(&(model_id(&1) == model))
  end

  defp model_entries(%{"data" => entries}) when is_list(entries), do: entries
  defp model_entries(%{"models" => entries}) when is_list(entries), do: entries
  defp model_entries(_body), do: []

  defp model_id(%{} = entry),
    do: Map.get(entry, "id") || Map.get(entry, "model") || Map.get(entry, "name")

  defp model_id(_entry), do: nil

  defp local_runtime_present(%{provider_endpoint_kind: "local_endpoint"}), do: true
  defp local_runtime_present(_profile), do: nil

  defp diagnostic_code({:voice_http_error, _status}), do: :voice_provider_http_error
  defp diagnostic_code({:voice_transport_error, _reason}), do: :voice_provider_unreachable
  defp diagnostic_code(:missing_local_voice_base_url), do: :voice_provider_base_url_missing
  defp diagnostic_code({:voice_local_host_denied, _host}), do: :provider_host_denied
  defp diagnostic_code({:voice_remote_host_denied, _reason}), do: :provider_host_denied
  defp diagnostic_code({:voice_remote_https_required, _scheme}), do: :invalid_provider_base_url
  defp diagnostic_code(:voice_endpoint_credentials_in_url_denied), do: :invalid_provider_base_url
  defp diagnostic_code(:voice_endpoint_query_denied), do: :invalid_provider_base_url
  defp diagnostic_code(:voice_endpoint_fragment_denied), do: :invalid_provider_base_url

  defp diagnostic_code({:voice_credential_missing, _provider}),
    do: :voice_provider_credential_missing

  defp diagnostic_code({:voice_credential_unavailable, _provider, _reason}),
    do: :voice_provider_credential_unavailable

  defp diagnostic_code(_reason), do: :voice_provider_probe_failed

  defp unavailable_packet, do: %{source: :unavailable}
end
