defmodule AllbertAssist.Voice.LocalRuntime.Router do
  @moduledoc """
  Plug router for the Allbert local voice runtime endpoint.

  The router intentionally exposes only the narrow OpenAI-compatible voice
  surface consumed by the v0.48 local voice adapter.
  """

  use Plug.Router

  alias AllbertAssist.Runtime.Redactor
  alias AllbertAssist.Voice.LocalRuntime
  alias AllbertAssist.Voice.LocalRuntime.Auth
  alias AllbertAssist.Voice.LocalRuntime.Config

  @max_multipart_bytes 10_485_760

  plug(:match)

  plug(Plug.Parsers,
    parsers: [:urlencoded, {:multipart, length: @max_multipart_bytes}, :json],
    pass: ["*/*"],
    json_decoder: Jason
  )

  plug(:dispatch)

  def init(opts), do: Config.build(opts)

  def call(conn, opts) do
    config = runtime_config(opts)

    conn
    |> Plug.Conn.put_private(:allbert_voice_local_runtime_config, config)
    |> super(config)
  end

  get "/v1/models" do
    json(conn, 200, LocalRuntime.models(runtime_config(conn)))
  end

  get "/models" do
    json(conn, 200, LocalRuntime.models(runtime_config(conn)))
  end

  get "/v1/doctor" do
    json(conn, 200, LocalRuntime.doctor(runtime_config(conn)))
  end

  get "/doctor" do
    json(conn, 200, LocalRuntime.doctor(runtime_config(conn)))
  end

  post "/v1/audio/transcriptions" do
    handle_transcription(conn, runtime_config(conn))
  end

  post "/audio/transcriptions" do
    handle_transcription(conn, runtime_config(conn))
  end

  post "/v1/audio/speech" do
    handle_speech(conn, runtime_config(conn))
  end

  post "/audio/speech" do
    handle_speech(conn, runtime_config(conn))
  end

  match _ do
    json(conn, 404, %{error: %{code: "not_found", message: "Not found"}})
  end

  defp handle_transcription(conn, opts) do
    with :ok <- authorized(conn, opts),
         {:ok, upload} <- upload(conn.params),
         {:ok, result} <- LocalRuntime.transcribe(upload.path, conn.params, opts) do
      json(conn, 200, %{
        text: result.transcript,
        duration_ms: Map.get(result, :duration_ms),
        usage: Map.get(result, :usage, %{source: :unavailable})
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp handle_speech(conn, opts) do
    with :ok <- authorized(conn, opts),
         {:ok, text} <- speech_text(conn.body_params),
         {:ok, result} <- LocalRuntime.synthesize(text, conn.body_params, opts) do
      conn
      |> Plug.Conn.put_resp_content_type(Map.get(result, :mime_type, "audio/wav"))
      |> Plug.Conn.send_resp(200, result.audio)
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp upload(%{"file" => %Plug.Upload{} = upload}), do: {:ok, upload}
  defp upload(%{file: %Plug.Upload{} = upload}), do: {:ok, upload}
  defp upload(_params), do: {:error, :local_voice_audio_file_missing}

  defp speech_text(%{"input" => input}) when is_binary(input) and input != "", do: {:ok, input}
  defp speech_text(%{input: input}) when is_binary(input) and input != "", do: {:ok, input}
  defp speech_text(_params), do: {:error, :local_voice_text_missing}

  defp runtime_config(%Plug.Conn{} = conn),
    do: Map.fetch!(conn.private, :allbert_voice_local_runtime_config)

  defp runtime_config(%{base_url: _base_url} = config), do: config
  defp runtime_config(opts), do: init(opts)

  defp authorized(conn, opts) do
    if Auth.authorized?(conn, opts), do: :ok, else: {:error, :local_voice_runtime_token_required}
  end

  defp error(conn, reason) do
    status = status_for(reason)

    json(conn, status, %{
      error: %{
        code: code_for(reason),
        message: inspect(Redactor.redact(reason))
      }
    })
  end

  defp status_for(:local_voice_audio_file_missing), do: 400
  defp status_for(:local_voice_text_missing), do: 400
  defp status_for(:local_voice_runtime_token_required), do: 401
  defp status_for(:local_voice_model_missing), do: 400
  defp status_for({:local_voice_model_unavailable, _model}), do: 404
  defp status_for({:local_voice_text_too_large, _size, _max}), do: 413
  defp status_for({:local_voice_backend_unavailable, _capability, _codes}), do: 503
  defp status_for({:local_voice_backend_http_error, _status}), do: 502
  defp status_for({:local_voice_backend_transport_error, _reason}), do: 503
  defp status_for(_reason), do: 500

  defp code_for(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp code_for({reason, _one}) when is_atom(reason), do: Atom.to_string(reason)
  defp code_for({reason, _one, _two}) when is_atom(reason), do: Atom.to_string(reason)
  defp code_for({reason, _one, _two, _three}) when is_atom(reason), do: Atom.to_string(reason)
  defp code_for(_reason), do: "local_voice_runtime_error"

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end
end
