defmodule AllbertAssist.Mcp.Registry.PulseMcpTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Mcp.Registry.PulseMcp
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root = Path.join(System.tmp_dir!(), "allbert-pulsemcp-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "search parses public PulseMCP server metadata" do
    configure_external("api.pulsemcp.com", "/servers")

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["query"] == "weather"
      assert conn.query_params["count_per_page"] == "5"

      Plug.Conn.send_resp(
        conn,
        200,
        Jason.encode!(McpRegistryFixtures.pulsemcp_weather_response())
      )
    end)

    assert {:ok, [result]} =
             PulseMcp.search("weather", %{
               require_configured_secrets?: false,
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               limit: 5
             })

    assert result.provider == :pulsemcp
    assert result.remote_server_id == "weather-pulse"
    assert result.repository_url == "https://github.com/acme/weather-pulse"
    assert result.server_url == "https://weather.example/mcp"
    assert result.signals.github_stars == 120
  end

  test "enabled PulseMCP source requires configured secret refs before query" do
    assert {:ok, _setting} =
             Settings.put(
               "mcp.discovery.sources.pulsemcp.api_key_ref",
               "secret://mcp/pulsemcp/api_key",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put(
               "mcp.discovery.sources.pulsemcp.tenant_ref",
               "secret://mcp/pulsemcp/tenant",
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.sources.pulsemcp.enabled", true, %{audit?: false})

    assert {:missing_secret, "secret://mcp/pulsemcp/api_key"} = PulseMcp.configured_status()

    assert {:error, {:missing_secret, "secret://mcp/pulsemcp/api_key"}} =
             PulseMcp.search("weather", %{
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               limit: 5
             })
  end

  defp configure_external(host, path) do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", [host], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", [path], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["GET"], %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
