defmodule AllbertAssist.PublicProtocol.HttpIngressTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.HttpIngress
  alias AllbertAssist.PublicProtocol.Mcp.Runtime
  alias AllbertAssist.PublicProtocol.RateLimiter
  alias AllbertAssist.PublicProtocol.TokenAuth
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    root = temp_root("public-http-ingress")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    RateLimiter.reset_for_test()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      RateLimiter.reset_for_test()
      File.rm_rf!(root)
    end)

    :ok
  end

  test "body cap and secure headers come from Settings Central" do
    assert {:ok, _setting} =
             Settings.put("public_protocol.max_body_bytes", 1024, %{audit?: false})

    assert HttpIngress.max_body_bytes() == 1024
    assert :ok = HttpIngress.content_length_allowed?("1024", HttpIngress.max_body_bytes())
    assert {:error, :body_too_large} = HttpIngress.content_length_allowed?("1025", 1024)

    assert {"content-security-policy", "default-src 'none'; frame-ancestors 'none'"} in HttpIngress.api_secure_headers()
    assert {"cache-control", "no-store"} in HttpIngress.api_secure_headers()
  end

  test "MCP HTTP enablement is independent from MCP stdio enablement" do
    enable_mcp_http!()
    allow_tools!(["direct_answer"])

    assert Runtime.surface_enabled?("mcp_http")
    refute Runtime.surface_enabled?("mcp_stdio")

    assert {:ok, [tool]} = Runtime.enabled_tools("mcp_http")
    assert tool.name == "direct_answer"
    assert {:ok, []} = Runtime.enabled_tools("mcp_stdio")
  end

  test "token authentication and rate limits use Settings Central client entries" do
    enable_mcp_http!()
    {:ok, created} = TokenAuth.create(:mcp_http, "claude", context())
    set_rate_limit!("claude", %{"limit" => 1, "period_ms" => 60_000, "burst" => 0})

    headers = [
      {"x-allbert-client-id", "claude"},
      {"authorization", "Bearer #{created.token}"}
    ]

    assert {:ok, auth} = HttpIngress.authenticate("mcp_http", headers)
    assert auth.client_id == "claude"
    assert auth.rate_limit == %{"limit" => 1, "period_ms" => 60_000, "burst" => 0}

    assert :ok = HttpIngress.rate_limit(auth)
    assert {:error, :rate_limited} = HttpIngress.rate_limit(auth)
  end

  test "origin and MCP protocol version validation reject before runtime work" do
    assert :ok = HttpIngress.validate_origin([{"origin", "http://localhost:4000"}], "127.0.0.1")

    assert {:error, :origin_denied} =
             HttpIngress.validate_origin([{"origin", "https://evil.example"}], "127.0.0.1")

    assert {:error, :origin_denied} =
             HttpIngress.validate_origin([{"origin", "http://localhost:4000"}], "example.com")

    assert :ok =
             HttpIngress.validate_mcp_protocol_version([{"mcp-protocol-version", "2025-06-18"}])

    assert {:error, error} =
             HttpIngress.validate_mcp_protocol_version([{"mcp-protocol-version", "2025-11-25"}])

    assert error.message == "Unsupported MCP protocol version."
  end

  defp enable_mcp_http! do
    assert {:ok, _setting} = Settings.put("mcp_server.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp_server.streamable_http.enabled", true, %{audit?: false})
  end

  defp allow_tools!(tools) do
    assert {:ok, _setting} = Settings.put("mcp_server.tools_enabled", tools, %{audit?: false})
  end

  defp set_rate_limit!(client_id, rate_limit) do
    {:ok, clients} = Settings.get("mcp_server.clients")
    entry = Map.fetch!(clients, client_id)
    updated = Map.put(clients, client_id, Map.put(entry, "rate_limit", rate_limit))

    assert {:ok, _setting} = Settings.put("mcp_server.clients", updated, %{audit?: false})
  end

  defp context, do: %{actor: "test", channel: "test", audit?: false}

  defp temp_root(prefix) do
    Path.join(System.tmp_dir!(), "allbert-#{prefix}-#{System.unique_integer([:positive])}")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
