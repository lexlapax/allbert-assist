defmodule AllbertAssistWeb.Plugs.PublicProtocolHeaders do
  @moduledoc "Applies the v0.51 API secure-header posture."

  import Plug.Conn

  alias AllbertAssist.PublicProtocol.HttpIngress

  def init(opts), do: opts

  def call(conn, _opts) do
    Enum.reduce(HttpIngress.api_secure_headers(), conn, fn {name, value}, acc ->
      put_resp_header(acc, name, value)
    end)
  end
end
