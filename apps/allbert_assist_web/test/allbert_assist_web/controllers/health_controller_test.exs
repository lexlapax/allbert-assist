defmodule AllbertAssistWeb.HealthControllerTest do
  @moduledoc "v0.62 M5 — the /health route serves a bounded JSON snapshot."
  use AllbertAssistWeb.ConnCase, async: true

  test "GET /health returns a JSON runtime snapshot", %{conn: conn} do
    conn = get(conn, ~p"/health")

    # 200 healthy / 503 degraded — both are valid depending on test runtime.
    assert conn.status in [200, 503]
    body = json_response(conn, conn.status)
    assert body["status"] in ["ok", "degraded"]
    assert Map.has_key?(body, "runtime")
    assert Map.has_key?(body, "database")
    assert Map.has_key?(body, "channels")
    # No secret material in a health snapshot.
    refute inspect(body) =~ "secret"
    refute inspect(body) =~ "api_key"
  end
end
