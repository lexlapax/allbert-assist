defmodule AllbertAssistWeb.PublicProtocol.WhatsAppWebhookController do
  @moduledoc """
  WhatsApp Cloud API signed-webhook ingress substrate.

  v0.53 M4 stops at verified ingress. The WhatsApp adapter in M7 consumes this
  route after parser/adapter mapping exists.
  """

  use AllbertAssistWeb, :controller

  def verify(conn, %{"hub.challenge" => challenge}) do
    challenge = conn.private[:allbert_public_protocol_webhook_challenge] || challenge

    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(200, challenge)
  end

  def verify(conn, _params) do
    conn
    |> put_status(400)
    |> json(%{"error" => %{"code" => "missing_webhook_challenge"}})
  end

  def handle(conn, params) do
    raw_body = conn.private[:allbert_public_protocol_raw_body] || ""

    conn
    |> put_status(202)
    |> json(%{
      "status" => "accepted",
      "surface" => "whatsapp_webhook",
      "phone_number_id" => conn.path_params["phone_number_id"],
      "object" => Map.get(params, "object"),
      "raw_body_sha256" => sha256(raw_body)
    })
  end

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end
end
