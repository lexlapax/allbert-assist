defmodule AllbertAssistWeb.ThemeController do
  use AllbertAssistWeb, :controller

  alias AllbertAssist.Theme.Tokens

  def user(conn, _params) do
    conn
    |> put_resp_content_type("text/css")
    |> put_resp_header("cache-control", "no-store")
    |> text(Tokens.user_css())
  end
end
