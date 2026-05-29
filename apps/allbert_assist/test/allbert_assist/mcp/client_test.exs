defmodule AllbertAssist.Mcp.ClientTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Mcp.Client
  alias AllbertAssist.Mcp.Doctor
  alias AllbertAssist.Mcp.ServerConfig
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-mcp-client-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "lists tools and resources over the HTTP transport through RequestSpec policy" do
    configure_external()
    configure_http_server()
    stub_http_mcp()

    assert {:ok, config} = ServerConfig.resolve("demo")

    assert {:ok, tools} =
             Client.list_tools(config, %{mcp: %{req_plug: {Req.Test, __MODULE__}}})

    assert [%{"name" => "search"}] = tools.tools
    assert tools.protocol_version == "2025-03-26"

    assert {:ok, resources} =
             Client.list_resources(config, %{mcp: %{req_plug: {Req.Test, __MODULE__}}})

    assert [%{"uri" => "file:///demo.md"}] = resources.resources

    assert {:ok, doctor} =
             Doctor.diagnose("demo", %{mcp: %{req_plug: {Req.Test, __MODULE__}}})

    assert doctor.endpoint_ok
    assert doctor.tools_listable
    assert doctor.resources_listable
    assert doctor.tool_count == 1
    assert doctor.resource_count == 1
    assert doctor.redacted_host == "example.com"
  end

  test "lists resources over a bounded stdio process with explicit argv", %{root: root} do
    script = Path.join(root, "mock_mcp_stdio.exs")
    File.mkdir_p!(root)

    File.write!(script, """
    for line <- IO.stream(:stdio, :line) do
      id_match = Regex.run(~r/"id":([0-9]+)/, line)
      method_match = Regex.run(~r/"method":"([^"]+)"/, line)

      if id_match && method_match do
        id = List.last(id_match)
        method = List.last(method_match)

        result =
          case method do
            "initialize" ->
              ~s({"protocolVersion":"2025-03-26","capabilities":{}})

            "resources/list" ->
              ~s({"resources":[{"uri":"file:///stdio.md","name":"stdio"}]})

            _other ->
              ~s({})
          end

        IO.puts(~s({"jsonrpc":"2.0","id":\#{id},"result":\#{result}}))
      end
    end
    """)

    configure_stdio_server(script)

    assert {:ok, config} = ServerConfig.resolve("stdio_demo")
    assert {:ok, resources} = Client.list_resources(config, %{})

    assert [%{"uri" => "file:///stdio.md"}] = resources.resources
  end

  defp configure_http_server do
    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.transport", "streamable_http", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.base_url", "https://example.com/mcp", %{audit?: false})

    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", true, %{audit?: false})
  end

  defp configure_stdio_server(script) do
    assert {:ok, _setting} =
             Settings.put("mcp.stdio.allowed_launchers", ["elixir"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_demo.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_demo.transport", "stdio", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_demo.command", "elixir", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_demo.args", [script], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_demo.enabled", true, %{audit?: false})
  end

  defp configure_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/mcp"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["POST"], %{audit?: false})
  end

  defp stub_http_mcp do
    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      request = Jason.decode!(body)

      result =
        case request["method"] do
          "initialize" ->
            %{"protocolVersion" => "2025-03-26", "capabilities" => %{}}

          "tools/list" ->
            %{
              "tools" => [%{"name" => "search", "description" => "Search.", "inputSchema" => %{}}]
            }

          "resources/list" ->
            %{"resources" => [%{"uri" => "file:///demo.md", "name" => "demo"}]}
        end

      response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})

      Plug.Conn.send_resp(conn, 200, response)
    end)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
