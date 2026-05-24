defmodule AllbertAssistWeb.Plugs.ContentSecurityPolicy do
  @moduledoc false

  import Plug.Conn

  @browser_policy [
    "default-src 'self'",
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'self' ws: wss:",
    "script-src 'self'",
    "base-uri 'self'",
    "frame-ancestors 'none'",
    "object-src 'none'"
  ]

  @theme_policy [
    "default-src 'none'",
    "style-src 'self'",
    "img-src 'self' data:",
    "font-src 'self'",
    "connect-src 'none'",
    "script-src 'none'",
    "base-uri 'none'",
    "frame-ancestors 'none'",
    "object-src 'none'"
  ]

  def init(policy), do: policy

  def call(conn, policy) do
    put_resp_header(conn, "content-security-policy", policy(policy))
  end

  defp policy(:theme), do: Enum.join(@theme_policy, "; ")
  defp policy(_policy), do: Enum.join(@browser_policy, "; ")
end
