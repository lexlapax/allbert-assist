defmodule AllbertAssistWeb.Plugs.PublicProtocolBodyReader do
  @moduledoc """
  Settings-bound body reader for public protocol parser reads.
  """

  alias AllbertAssist.PublicProtocol.HttpIngress

  def read_body(conn, opts) do
    Plug.Conn.read_body(conn, public_protocol_opts(conn, opts))
  end

  defp public_protocol_opts(conn, opts) do
    if HttpIngress.public_path?(conn.request_path) do
      Keyword.put(opts, :length, HttpIngress.max_body_bytes())
    else
      opts
    end
  end
end
