defmodule AllbertAssistWeb.Plugs.McpProtocolVersion do
  @moduledoc "Rejects unsupported MCP HTTP protocol versions before runtime work."

  import Plug.Conn

  alias AllbertAssist.PublicProtocol.HttpIngress

  def init(opts), do: opts

  def call(conn, _opts) do
    case HttpIngress.validate_mcp_protocol_version(conn.req_headers) do
      :ok -> conn
      {:error, reason} -> send_error(conn, reason)
    end
  end

  defp send_error(conn, reason) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(HttpIngress.status(reason), Jason.encode!(HttpIngress.error_body(reason)))
    |> halt()
  end
end
