defmodule AllbertAssistWeb.PublicProtocol.WhatsAppWebhookController do
  @moduledoc """
  WhatsApp Cloud API signed-webhook ingress substrate.

  The M4 public-protocol substrate authenticates this route before JSON parsing.
  M7 hands verified payloads to the WhatsApp channel adapter.
  """

  use AllbertAssistWeb, :controller

  alias AllbertAssist.Channels.WhatsApp.Adapter, as: WhatsAppAdapter
  alias AllbertAssistWeb.PackReadiness
  alias AllbertAssistWeb.PackReadiness.HTTPGate

  def verify(conn, %{"hub.challenge" => challenge}) do
    if current?(conn) do
      challenge = conn.private[:allbert_public_protocol_webhook_challenge] || challenge

      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, challenge)
    else
      HTTPGate.unavailable(conn)
    end
  end

  def verify(conn, _params) do
    if current?(conn) do
      conn
      |> put_status(400)
      |> json(%{"error" => %{"code" => "missing_webhook_challenge"}})
    else
      HTTPGate.unavailable(conn)
    end
  end

  def handle(conn, params) do
    if current?(conn) do
      raw_body = conn.private[:allbert_public_protocol_raw_body] || ""
      auth = conn.assigns[:public_protocol_auth] || %{}

      adapter_result =
        WhatsAppAdapter.handle_webhook_payload(params, auth,
          allbert_pack_epoch: conn.private[:allbert_pack_epoch]
        )
        |> normalize_adapter_result()

      conn
      |> put_status(202)
      |> json(%{
        "status" => "accepted",
        "surface" => "whatsapp_webhook",
        "phone_number_id" => conn.path_params["phone_number_id"],
        "object" => Map.get(params, "object"),
        "raw_body_sha256" => sha256(raw_body),
        "adapter" => adapter_result
      })
    else
      HTTPGate.unavailable(conn)
    end
  end

  defp normalize_adapter_result({:ok, summary}), do: stringify(summary)

  defp normalize_adapter_result({:error, reason}),
    do: %{"status" => "error", "reason" => inspect(reason)}

  defp stringify(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify(value)} end)
  end

  defp stringify(value), do: value

  defp sha256(value) do
    :crypto.hash(:sha256, value)
    |> Base.encode16(case: :lower)
  end

  defp current?(conn), do: PackReadiness.validate_conn(conn) == :ok
end
