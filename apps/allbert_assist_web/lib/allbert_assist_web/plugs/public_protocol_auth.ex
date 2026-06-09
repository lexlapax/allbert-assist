defmodule AllbertAssistWeb.Plugs.PublicProtocolAuth do
  @moduledoc """
  Authenticates and rate-limits HTTP public protocol clients.
  """

  import Plug.Conn

  alias AllbertAssist.PublicProtocol.HttpIngress

  def init(opts), do: Map.new(opts)

  def call(conn, %{surface: surface}) do
    headers = conn.req_headers

    with :ok <- HttpIngress.validate_origin(headers, conn.host),
         {:ok, auth} <- HttpIngress.authenticate(surface, headers),
         :ok <- HttpIngress.rate_limit(auth) do
      conn
      |> assign(:public_protocol_auth, auth)
      |> assign(:public_protocol_context, HttpIngress.public_context(auth))
    else
      {:error, reason} -> send_error(conn, reason)
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
