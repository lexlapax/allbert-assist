defmodule AllbertAssistWeb.PageControllerTest do
  use AllbertAssistWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    html = html_response(conn, 200)

    assert html =~ "Signal-driven assistant workspace"
    assert html =~ "Open workspace"
    refute html =~ "Phoenix Framework"
  end
end
