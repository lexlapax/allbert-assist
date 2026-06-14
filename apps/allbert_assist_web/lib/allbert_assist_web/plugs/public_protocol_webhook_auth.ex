defmodule AllbertAssistWeb.Plugs.PublicProtocolWebhookAuth do
  @moduledoc """
  Pre-parser signature authentication for public signed webhooks.

  This plug runs before `Plug.Parsers`, reads and caches the raw request body for
  signed webhook POSTs, verifies the HMAC over those exact bytes, and leaves the
  cached body for `PublicProtocolBodyReader` to hand back to the JSON parser.
  """

  import Plug.Conn

  alias AllbertAssist.PublicProtocol.HttpIngress

  @raw_body_private :allbert_public_protocol_raw_body
  @surface "whatsapp_webhook"

  def init(opts), do: opts

  def call(%{method: "POST", request_path: path} = conn, _opts) do
    if HttpIngress.webhook_path?(path) do
      authenticate_post(conn, path)
    else
      conn
    end
  end

  def call(%{method: "GET", request_path: path} = conn, _opts) do
    if HttpIngress.webhook_path?(path) do
      authenticate_challenge(conn, path)
    else
      conn
    end
  end

  def call(conn, _opts), do: conn

  defp authenticate_post(conn, path) do
    case Plug.Conn.read_body(conn, length: HttpIngress.max_body_bytes()) do
      {:ok, raw_body, conn} ->
        conn = put_private(conn, @raw_body_private, raw_body)

        case HttpIngress.authenticate_webhook(@surface, conn.req_headers, raw_body, path) do
          {:ok, auth} -> assign_auth(conn, auth)
          {:error, reason} -> send_error(conn, reason)
        end

      {:more, _partial_body, conn} ->
        send_error(conn, :body_too_large)

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  defp authenticate_challenge(conn, path) do
    conn = fetch_query_params(conn)

    case HttpIngress.authenticate_webhook_challenge(
           @surface,
           conn.req_headers,
           path,
           conn.query_params
         ) do
      {:ok, challenge, auth} ->
        conn
        |> put_private(:allbert_public_protocol_webhook_challenge, challenge)
        |> assign_auth(auth)

      {:error, reason} ->
        send_error(conn, reason)
    end
  end

  defp assign_auth(conn, auth) do
    conn
    |> assign(:public_protocol_auth, auth)
    |> assign(:public_protocol_context, HttpIngress.public_context(auth))
  end

  defp send_error(conn, reason) do
    conn
    |> put_secure_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(HttpIngress.status(reason), Jason.encode!(HttpIngress.error_body(reason)))
    |> halt()
  end

  defp put_secure_headers(conn) do
    Enum.reduce(HttpIngress.api_secure_headers(), conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end
end
