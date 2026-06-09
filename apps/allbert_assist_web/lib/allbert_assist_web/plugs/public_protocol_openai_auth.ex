defmodule AllbertAssistWeb.Plugs.PublicProtocolOpenAIAuth do
  @moduledoc """
  Authenticates OpenAI-compatible HTTP public protocol clients.
  """

  import Plug.Conn

  alias AllbertAssist.PublicProtocol.HttpIngress
  alias AllbertAssist.PublicProtocol.OpenAI.Mapping

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
      {:error, reason} -> send_error(conn, Mapping.ingress_error(reason))
    end
  end

  defp send_error(conn, error) do
    conn
    |> put_secure_headers()
    |> put_resp_content_type("application/json")
    |> send_resp(Mapping.error_status(error), Jason.encode!(Mapping.error_body(error)))
    |> halt()
  end

  defp put_secure_headers(conn) do
    Enum.reduce(HttpIngress.api_secure_headers(), conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end
end
