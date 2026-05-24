defmodule AllbertAssistWeb.ThemeController do
  use AllbertAssistWeb, :controller

  alias AllbertAssist.Theme.Tokens
  alias AllbertAssist.Theme.Version

  def user(conn, _params) do
    css = Tokens.user_css()
    etag = etag(Version.stylesheet_version())

    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("cache-control", "private, max-age=0, must-revalidate")
    |> put_resp_header("etag", etag)
    |> maybe_send_css(css, etag)
  end

  defp maybe_send_css(conn, css, etag) do
    if etag in get_req_header(conn, "if-none-match") do
      send_resp(conn, 304, "")
    else
      text(conn, css)
    end
  end

  defp etag(version), do: ~s("#{version}")
end
