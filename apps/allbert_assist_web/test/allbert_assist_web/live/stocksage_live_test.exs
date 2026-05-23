defmodule StockSageWeb.RouteRemovalTest do
  use AllbertAssistWeb.ConnCase, async: true

  test "old StockSage operator routes are absent in v0.32", %{conn: conn} do
    for path <- [
          "/stocksage",
          "/stocksage/analyses",
          "/stocksage/analyses/ana_test",
          "/stocksage/queue",
          "/stocksage/trends"
        ] do
      conn = conn |> recycle() |> get(path)
      assert html_response(conn, 404) == "Not Found"
    end
  end
end
