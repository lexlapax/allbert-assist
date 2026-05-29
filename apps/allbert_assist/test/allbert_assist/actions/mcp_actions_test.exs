defmodule AllbertAssist.Actions.McpActionsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-mcp-actions-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    configure_external()
    configure_http_server()
    stub_http_mcp()

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "MCP read-only actions run through the action runner and write redacted audit", %{
    root: root
  } do
    context = %{actor: "local", channel: :test, mcp: %{req_plug: {Req.Test, __MODULE__}}}

    assert {:ok, %{status: :completed} = doctor} =
             Runner.run("mcp_doctor_server", %{server_id: "demo"}, context)

    assert doctor.doctor.endpoint_ok
    assert doctor.doctor.tool_count == 1

    assert {:ok, %{status: :completed, tools: tools}} =
             Runner.run("mcp_list_tools", %{server_id: "demo"}, context)

    assert [%{"name" => "search"}] = tools

    assert {:ok, %{status: :completed, resources: resources}} =
             Runner.run("mcp_list_resources", %{server_id: "demo"}, context)

    assert [%{"uri" => "file:///demo.md"}] = resources

    audit = File.read!(Path.join([root, "mcp", "audit", audit_file()]))
    assert audit =~ "mcp_doctor_server"
    assert audit =~ "mcp_list_tools"
    refute audit =~ "secret-token"
  end

  defp configure_http_server do
    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.transport", "streamable_http", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.base_url", "https://example.com/mcp", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.headers", %{"X-Demo" => "secret-token"}, %{
               audit?: false
             })

    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", true, %{audit?: false})
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

  defp audit_file do
    DateTime.utc_now()
    |> Calendar.strftime("%Y-%m.md")
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
