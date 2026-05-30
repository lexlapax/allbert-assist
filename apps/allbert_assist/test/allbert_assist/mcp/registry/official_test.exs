defmodule AllbertAssist.Mcp.Registry.OfficialTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Mcp.Registry.Official
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-official-registry-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "search parses official server.json metadata through HTTP policy" do
    configure_external("registry.modelcontextprotocol.io", "/v0.1/servers")

    Req.Test.stub(__MODULE__, fn conn ->
      conn = Plug.Conn.fetch_query_params(conn)
      assert conn.query_params["limit"]

      Plug.Conn.send_resp(conn, 200, Jason.encode!(McpRegistryFixtures.official_response()))
    end)

    assert {:ok, [result]} =
             Official.search("weather", %{
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               limit: 5,
               max_pages: 1
             })

    assert result.provider == :official
    assert result.remote_server_id == "io.github.acme/weather-mcp"
    assert result.description == "Weather forecast and alert tools."
    assert result.repository_url == "https://github.com/acme/weather-mcp"
    assert result.transport_kinds == ["stdio"]
    assert {:ok, manifest} = Official.fetch_manifest(result.manifest, %{})
    assert manifest["name"] == "io.github.acme/weather-mcp"
  end

  test "search fails closed when external policy denies registry egress" do
    assert {:error, {:http_policy_denied, :external_services_disabled}} =
             Official.search("weather", %{
               context: %{external: %{req_plug: {Req.Test, __MODULE__}}},
               limit: 5,
               max_pages: 1
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
