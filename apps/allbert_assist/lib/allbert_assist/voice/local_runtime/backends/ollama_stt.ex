defmodule AllbertAssist.Voice.LocalRuntime.Backends.OllamaSTT do
  @moduledoc """
  Local STT backend for the Allbert local voice runtime.

  Ollama is treated as a local backend, not as the public voice endpoint. The
  public endpoint remains Allbert-owned so Settings Central, Security Central,
  redaction, and the OpenAI-compatible surface stay consistent.
  """

  alias AllbertAssist.Voice.LocalRuntime.Config

  @spec doctor(Config.t()) :: map()
  def doctor(config) do
    case request(:get, models_url(config), [], config) do
      {:ok, %{status: status, body: body}} when status >= 200 and status < 300 ->
        entries = body |> decoded_body() |> model_entries()
        available? = Enum.any?(entries, &(model_id(&1) == config.ollama_stt_model))

        %{
          backend: :ollama,
          available?: available?,
          model: config.ollama_stt_model,
          redacted_host: URI.parse(config.ollama_base_url).host,
          diagnostic_codes: if(available?, do: [], else: [:local_ollama_stt_model_missing])
        }

      {:ok, %{status: status}} ->
        unavailable(config, {:local_ollama_http_error, status})

      {:error, reason} ->
        unavailable(config, reason)
    end
  end

  @spec transcribe(String.t(), map(), Config.t()) :: {:ok, map()} | {:error, term()}
  def transcribe(path, _params, config) when is_binary(path) do
    with {:ok, audio} <- File.read(path),
         {:ok, response} <-
           request(
             :post,
             transcriptions_url(config),
             [
               form_multipart: [
                 file: {audio, filename: Path.basename(path)},
                 model: config.ollama_stt_model,
                 response_format: "json"
               ]
             ],
             config
           ),
         :ok <- successful_response(response),
         body = decoded_body(response.body),
         {:ok, transcript} <- transcript_text(body) do
      {:ok,
       %{
         transcript: transcript,
         duration_ms: duration_ms(body),
         usage: provider_usage(body)
       }}
    else
      {:error, reason} -> {:error, normalize_error(reason)}
    end
  end

  defp request(method, url, opts, config) do
    [
      method: method,
      url: url,
      receive_timeout: config.timeout_ms,
      retry: false,
      redirect: false,
      max_redirects: 0
    ]
    |> Keyword.merge(opts)
    |> Keyword.merge(config.req_options)
    |> Req.request()
    |> case do
      {:ok, response} ->
        {:ok, response}

      {:error, %Req.TransportError{} = error} ->
        {:error, {:local_ollama_transport_error, error.reason}}

      {:error, reason} ->
        {:error, {:local_ollama_transport_error, reason}}
    end
  end

  defp successful_response(%{status: status}) when status >= 200 and status < 300, do: :ok
  defp successful_response(%{status: status}), do: {:error, {:local_ollama_http_error, status}}

  defp models_url(config), do: join_url(config.ollama_base_url, "/models")
  defp transcriptions_url(config), do: join_url(config.ollama_base_url, "/audio/transcriptions")

  defp join_url(base_url, path) do
    uri = URI.parse(base_url)

    joined =
      [String.trim(uri.path || "", "/"), String.trim(path, "/")]
      |> Enum.reject(&(&1 == ""))
      |> Enum.join("/")

    uri
    |> Map.put(:path, "/" <> joined)
    |> Map.put(:query, nil)
    |> Map.put(:fragment, nil)
    |> URI.to_string()
  end

  defp model_entries(%{"data" => entries}) when is_list(entries), do: entries
  defp model_entries(%{"models" => entries}) when is_list(entries), do: entries
  defp model_entries(_body), do: []

  defp decoded_body(body) when is_binary(body) do
    body = String.trim(body)

    cond do
      body == "" ->
        body

      String.contains?(body, "\n") ->
        body
        |> String.split("\n", trim: true)
        |> Enum.map(&decode_json_line/1)
        |> case do
          [decoded] -> decoded
          decoded -> decoded
        end

      true ->
        decode_json_line(body)
    end
  end

  defp decoded_body(body), do: body

  defp decode_json_line(line) do
    case Jason.decode(line) do
      {:ok, decoded} -> decoded
      {:error, _reason} -> line
    end
  end

  defp model_id(%{} = entry),
    do: Map.get(entry, "id") || Map.get(entry, "model") || Map.get(entry, "name")

  defp model_id(_entry), do: nil

  defp transcript_text(%{"text" => text}) when is_binary(text) do
    text = String.trim(text)
    if text == "", do: {:error, :empty_voice_transcript}, else: {:ok, text}
  end

  defp transcript_text(%{"transcript" => text}) when is_binary(text),
    do: transcript_text(%{"text" => text})

  defp transcript_text(_body), do: {:error, :missing_voice_transcript}

  defp duration_ms(%{"duration" => seconds}) when is_number(seconds), do: round(seconds * 1000)
  defp duration_ms(%{"duration_ms" => duration_ms}) when is_integer(duration_ms), do: duration_ms
  defp duration_ms(_body), do: nil

  defp provider_usage(%{"usage" => usage}) when is_map(usage),
    do: Map.put_new(usage, "source", "provider")

  defp provider_usage(_body), do: %{source: :unavailable}

  defp unavailable(config, reason) do
    %{
      backend: :ollama,
      available?: false,
      model: config.ollama_stt_model,
      redacted_host: URI.parse(config.ollama_base_url).host,
      diagnostic_codes: [diagnostic_code(reason)]
    }
  end

  defp normalize_error({:local_ollama_http_error, status}),
    do: {:local_voice_backend_http_error, status}

  defp normalize_error({:local_ollama_transport_error, reason}),
    do: {:local_voice_backend_transport_error, reason}

  defp normalize_error(reason), do: reason

  defp diagnostic_code({:local_ollama_http_error, _status}), do: :local_ollama_http_error
  defp diagnostic_code({:local_ollama_transport_error, _reason}), do: :local_ollama_unreachable
  defp diagnostic_code(_reason), do: :local_ollama_probe_failed
end
