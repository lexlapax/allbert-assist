defmodule AllbertAssistWeb.PublicProtocol.OpenAIController do
  @moduledoc """
  OpenAI-compatible HTTP API shim for v0.51.
  """

  use AllbertAssistWeb, :controller

  alias AllbertAssist.PublicProtocol.OpenAI.Mapping
  alias AllbertAssist.Runtime

  plug AllbertAssistWeb.Plugs.PublicProtocolOpenAIAuth,
       [surface: "openai_api"] when action in [:chat_completions, :models]

  def models(conn, _params) do
    case Mapping.models_response() do
      {:ok, body} -> json(conn, body)
      {:error, error} -> send_error(conn, error)
    end
  end

  def chat_completions(conn, params) do
    auth = conn.assigns.public_protocol_auth

    with {:ok, chat} <- Mapping.parse_chat_request(params, auth),
         {:ok, runtime_response} <- Runtime.submit_user_input(Mapping.runtime_request(chat, auth)),
         {:ok, body} <- Mapping.chat_completion(runtime_response, chat, auth) do
      send_chat_response(conn, chat, body)
    else
      {:error, %{status: _status} = error} -> send_error(conn, error)
      {:error, reason} -> send_error(conn, Mapping.runtime_error(reason))
    end
  end

  defp send_chat_response(conn, %{stream?: true}, body) do
    conn
    |> put_resp_content_type("text/event-stream")
    |> send_resp(200, Mapping.sse_payload(body))
  end

  defp send_chat_response(conn, _chat, body), do: json(conn, body)

  defp send_error(conn, error) do
    conn
    |> put_status(Mapping.error_status(error))
    |> json(Mapping.error_body(error))
  end
end
