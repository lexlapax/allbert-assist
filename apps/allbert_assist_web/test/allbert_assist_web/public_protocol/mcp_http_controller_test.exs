defmodule AllbertAssistWeb.PublicProtocol.McpHttpControllerTest do
  use AllbertAssistWeb.ConnCase, async: false, lane: :external_runtime_serial

  import Ecto.Query

  alias AllbertAssist.Channels.Event
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Settings
  alias AllbertAssistWeb.Plugs.PublicProtocolBodyCap
  alias AllbertAssistWeb.Plugs.PublicProtocolBodyReader

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-http-controller-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    RateLimiter.reset_for_test()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      RateLimiter.reset_for_test()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "tools/list requires token auth and returns only Settings-allowlisted tools", %{conn: conn} do
    enable_mcp_http!()
    allow_tools!(["direct_answer"])
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())

    conn =
      conn
      |> auth_conn(created.token)
      |> post_json(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list"})

    assert conn.status == 200
    assert [%{"name" => "direct_answer"}] = json_response(conn, 200)["result"]["tools"]

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "tools/call accepts JSON-string arguments for allowlisted tools", %{conn: conn} do
    enable_mcp_http!()
    allow_tools!(["direct_answer"])
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())

    conn =
      conn
      |> auth_conn(created.token)
      |> post_json(%{
        "jsonrpc" => "2.0",
        "id" => "call",
        "method" => "tools/call",
        "params" => %{
          "name" => "direct_answer",
          "arguments" => %{"text" => "hello from v0.51 manual validation"}
        }
      })

    assert conn.status == 200

    result = json_response(conn, 200)["result"]
    assert result["isError"] == false

    assert get_in(result, ["structuredContent", "runner_metadata", "action_name"]) ==
             "direct_answer"

    assert %{"status" => "completed", "message" => message} =
             Jason.decode!(get_in(result, ["content", Access.at(0), "text"]))

    assert is_binary(message)

    assert %Event{
             channel: "mcp_http",
             status: "processed",
             external_user_id: "claude",
             user_id: "public-protocol:claude"
           } =
             AllbertAssist.Repo.one(
               from(event in Event,
                 where: event.channel == "mcp_http" and event.status == "processed",
                 order_by: [desc: event.inserted_at],
                 limit: 1
               )
             )
  end

  test "missing token is denied before runtime dispatch", %{conn: conn} do
    enable_mcp_http!()

    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", "2025-06-18")
      |> post(
        ~p"/mcp",
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => "x", "method" => "tools/list"})
      )

    assert conn.status == 401
    assert json_response(conn, 401)["error"]["code"] == "missing_client_id"

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "rate limit rejects the second request before runtime work", %{conn: conn} do
    enable_mcp_http!()
    allow_tools!(["direct_answer"])
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())
    set_rate_limit!("claude", %{"limit" => 1, "period_ms" => 60_000, "burst" => 0})

    request = %{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list"}

    first =
      conn
      |> auth_conn(created.token)
      |> post_json(request)

    assert first.status == 200

    second =
      recycle(first)
      |> auth_conn(created.token)
      |> post_json(request)

    assert second.status == 429
    assert json_response(second, 429)["error"]["code"] == "rate_limited"

    assert get_resp_header(second, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]
  end

  test "unsupported MCP protocol versions are rejected", %{conn: conn} do
    enable_mcp_http!()
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())

    conn =
      conn
      |> auth_conn(created.token)
      |> put_req_header("mcp-protocol-version", "2025-11-25")
      |> post_json(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize"})

    assert conn.status == 400
    assert json_response(conn, 400)["error"]["message"] == "Unsupported MCP protocol version."

    assert get_resp_header(conn, "content-security-policy") == [
             "default-src 'none'; frame-ancestors 'none'"
           ]

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "resources/list and resources/read use the HTTP surface context", %{conn: conn} do
    enable_mcp_http!()
    allow_namespaces!(["stocksage.stocksage"])
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())

    list_conn =
      conn
      |> auth_conn(created.token)
      |> post_json(%{"jsonrpc" => "2.0", "id" => "resources", "method" => "resources/list"})

    assert [%{"uri" => uri, "name" => "stocksage.stocksage"}] =
             json_response(list_conn, 200)["result"]["resources"]

    read_conn =
      recycle(list_conn)
      |> auth_conn(created.token)
      |> post_json(%{
        "jsonrpc" => "2.0",
        "id" => "read",
        "method" => "resources/read",
        "params" => %{"uri" => uri}
      })

    [%{"text" => text}] = json_response(read_conn, 200)["result"]["contents"]
    assert Jason.decode!(text)["surface"] == "mcp_http"
  end

  test "resources/read returns JSON error with 404 for missing public resources", %{conn: conn} do
    enable_mcp_http!()
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())

    conn =
      conn
      |> auth_conn(created.token)
      |> post_json(%{
        "jsonrpc" => "2.0",
        "id" => "missing-resource",
        "method" => "resources/read",
        "params" => %{"uri" => "allbert://missing/namespace"}
      })

    assert conn.status == 404
    assert json_response(conn, 404)["error"]["message"] == "MCP resource was not found."
  end

  test "session header is echoed and DELETE is explicitly unsupported in v0.51", %{conn: conn} do
    enable_mcp_http!()
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())

    init_conn =
      conn
      |> auth_conn(created.token)
      |> put_req_header("mcp-session-id", "session-1")
      |> post_json(%{"jsonrpc" => "2.0", "id" => "init", "method" => "initialize"})

    assert get_resp_header(init_conn, "mcp-session-id") == ["session-1"]

    delete_conn =
      recycle(init_conn)
      |> auth_conn(created.token)
      |> delete(~p"/mcp")

    assert delete_conn.status == 405
    assert json_response(delete_conn, 405)["error"]["code"] == "method_not_allowed"
  end

  test "body cap rejects public protocol content-length before parser/runtime work" do
    assert {:ok, _setting} =
             Settings.put("public_protocol.max_body_bytes", 1024, %{audit?: false})

    conn =
      Phoenix.ConnTest.build_conn(:post, "/mcp", "{}")
      |> put_req_header("content-length", "1025")
      |> PublicProtocolBodyCap.call([])

    assert conn.halted
    assert conn.status == 413
    assert Jason.decode!(conn.resp_body)["error"]["code"] == "body_too_large"
  end

  test "body reader enforces Settings Central cap when content-length is unavailable" do
    assert {:ok, _setting} =
             Settings.put("public_protocol.max_body_bytes", 1024, %{audit?: false})

    conn =
      Phoenix.ConnTest.build_conn(:post, "/mcp", String.duplicate("x", 1025))
      |> delete_req_header("content-length")

    assert {:more, _partial, _conn} =
             PublicProtocolBodyReader.read_body(conn, length: 10_485_760)
  end

  test "non-loopback Origin is rejected on the HTTP public protocol route", %{conn: conn} do
    enable_mcp_http!()
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())

    conn =
      %{conn | host: "127.0.0.1"}
      |> auth_conn(created.token)
      |> put_req_header("origin", "https://evil.example")
      |> post_json(%{"jsonrpc" => "2.0", "id" => "tools", "method" => "tools/list"})

    assert conn.status == 403
    assert json_response(conn, 403)["error"]["code"] == "origin_denied"
  end

  test "MCP HTTP is not mounted through Hermes StreamableHTTP transport" do
    router_source = File.read!(Path.expand("../../../lib/allbert_assist_web/router.ex", __DIR__))

    endpoint_source =
      File.read!(Path.expand("../../../lib/allbert_assist_web/endpoint.ex", __DIR__))

    controller_source =
      File.read!(
        Path.expand(
          "../../../lib/allbert_assist_web/controllers/public_protocol/mcp_http_controller.ex",
          __DIR__
        )
      )

    refute router_source =~ "Hermes.Server.Transport.StreamableHTTP.Plug"
    refute endpoint_source =~ "Hermes.Server.Transport.StreamableHTTP.Plug"
    refute controller_source =~ "Hermes.Server.Transport.StreamableHTTP.Plug"
    refute router_source =~ "forward \"/mcp\""
  end

  defp auth_conn(conn, token, client_id \\ "claude") do
    conn
    |> put_req_header("x-allbert-client-id", client_id)
    |> put_req_header("authorization", "Bearer #{token}")
    |> put_req_header("content-type", "application/json")
    |> put_req_header("mcp-protocol-version", "2025-06-18")
  end

  defp post_json(conn, body), do: post(conn, ~p"/mcp", Jason.encode!(body))

  defp enable_mcp_http! do
    assert {:ok, _setting} = Settings.put("mcp_server.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp_server.streamable_http.enabled", true, %{audit?: false})
  end

  defp allow_tools!(tools) do
    assert {:ok, _setting} = Settings.put("mcp_server.tools_enabled", tools, %{audit?: false})
  end

  defp allow_namespaces!(namespaces) do
    assert {:ok, _setting} =
             Settings.put("mcp_server.memory_namespaces_enabled", namespaces, %{audit?: false})
  end

  defp set_rate_limit!(client_id, rate_limit) do
    {:ok, clients} = Settings.get("mcp_server.clients")
    entry = Map.fetch!(clients, client_id)
    updated = Map.put(clients, client_id, Map.put(entry, "rate_limit", rate_limit))

    assert {:ok, _setting} = Settings.put("mcp_server.clients", updated, %{audit?: false})
  end

  defp context, do: %{actor: "test", channel: "test", audit?: false}

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
