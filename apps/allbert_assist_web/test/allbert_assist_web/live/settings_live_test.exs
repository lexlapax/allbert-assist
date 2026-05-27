defmodule AllbertAssistWeb.SettingsRouteRemovalTest do
  use AllbertAssistWeb.ConnCase, async: false

  test "/settings is not an operator route in v0.32", %{conn: conn} do
    conn = get(conn, "/settings")
    assert html_response(conn, 404) == "Not Found"
  end
end
