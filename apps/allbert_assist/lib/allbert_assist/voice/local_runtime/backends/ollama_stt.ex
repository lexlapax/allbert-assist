defmodule AllbertAssist.Voice.LocalRuntime.Backends.OllamaSTT do
  @moduledoc """
  Local STT backend for the Allbert local voice runtime.

  Ollama is treated as a local backend, not as the public voice endpoint. The
  public endpoint remains Allbert-owned so Settings Central, Security Central,
  redaction, and the OpenAI-compatible surface stay consistent.
  """

  alias AllbertAssist.Pack.EffectGuard
  alias AllbertAssist.Voice.LocalRuntime.Config
  alias AllbertAssist.Voice.TranscriptResponse

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
         {:ok, transcript} <- TranscriptResponse.transcript_text(body) do
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
    with {:ok, epoch} <- carried_epoch(config.req_options) do
      request =
        [
          method: method,
          url: url,
          receive_timeout: config.timeout_ms,
          retry: false,
          redirect: false,
          max_redirects: 0
        ]
        |> Keyword.merge(opts)
        |> Keyword.merge(Keyword.delete(config.req_options, :allbert_pack_epoch))

      with :ok <- EffectGuard.validate(epoch),
           result <- Req.request(request) do
        handle_request_result(result)
      end
    end
  end

  defp handle_request_result({:ok, response}), do: {:ok, response}

  defp handle_request_result({:error, %Req.TransportError{} = error}),
    do: {:error, {:local_ollama_transport_error, error.reason}}

  defp handle_request_result({:error, reason}),
    do: {:error, {:local_ollama_transport_error, reason}}

  defp carried_epoch(opts) when is_list(opts) do
    case Keyword.fetch(opts, :allbert_pack_epoch) do
      {:ok, epoch} -> {:ok, epoch}
      :error -> {:error, :product_not_ready}
    end
  end

  defp carried_epoch(_opts), do: {:error, :product_not_ready}

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

  # unavailable/2 exists to REPORT why the backend is unavailable, so this must
  # total over the reasons that reach it. carried_epoch/1 returns a bare
  # :product_not_ready when req_options carry no epoch, which matched no clause
  # and raised FunctionClauseError — turning "unavailable, here is why" into a
  # crash, precisely when the caller wanted the diagnosis.
  defp diagnostic_code(:product_not_ready), do: :local_voice_backend_unavailable
  defp diagnostic_code(_reason), do: :local_voice_backend_unavailable
end
