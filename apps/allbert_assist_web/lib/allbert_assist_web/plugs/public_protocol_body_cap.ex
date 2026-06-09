defmodule AllbertAssistWeb.Plugs.PublicProtocolBodyCap do
  @moduledoc """
  Enforces public protocol body caps before Phoenix parses request bodies.
  """

  import Plug.Conn

  alias AllbertAssist.PublicProtocol.HttpIngress

  def init(opts), do: opts

  def call(conn, _opts) do
    if HttpIngress.public_path?(conn.request_path) do
      max = HttpIngress.max_body_bytes()
      length = conn |> get_req_header("content-length") |> List.first()

      case HttpIngress.content_length_allowed?(length, max) do
        :ok -> conn
        {:error, reason} -> send_error(conn, reason)
      end
    else
      conn
    end
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
