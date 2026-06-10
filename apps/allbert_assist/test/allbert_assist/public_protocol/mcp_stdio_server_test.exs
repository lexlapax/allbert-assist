defmodule AllbertAssist.PublicProtocol.McpStdioServerTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.PublicProtocol.Mcp.ProtocolVersions
  alias AllbertAssist.PublicProtocol.Mcp.Runtime
  alias AllbertAssist.PublicProtocol.Mcp.Server
  alias AllbertAssist.PublicProtocol.Mcp.StdioServer
  alias AllbertAssist.PublicProtocol.ResultReadback
  alias AllbertAssist.Settings
  alias Hermes.Server.Frame

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-stdio-server-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      File.rm_rf!(root)
    end)

    :ok
  end

  test "default-off stdio surface exposes no tools or resources" do
    assert Runtime.surface_enabled?() == false
    assert {:ok, []} = Runtime.enabled_tools()
    assert {:ok, []} = Runtime.enabled_resources()
  end

  test "enabled stdio surface exposes only settings-allowlisted public tools" do
    enable_mcp_stdio!()
    allow_tools!(["direct_answer"])

    assert {:ok, [tool]} = Runtime.enabled_tools()
    assert tool.name == "direct_answer"

    assert {:ok, specs} = Runtime.tool_specs()
    assert [{"direct_answer", opts}] = specs
    assert opts[:input_schema]["properties"]["text"]["type"] == "string"
    assert opts[:annotations]["readOnlyHint"] == true
  end

  test "Hermes server init registers allowlisted tools and resources on the frame" do
    enable_mcp_stdio!()
    allow_tools!(["direct_answer"])
    allow_namespaces!(["stocksage.stocksage"])

    assert {:ok, frame} =
             Server.init(%{"name" => "fixture-client"}, Frame.new())

    assert [%{name: "direct_answer"}] = Frame.get_tools(frame)
    assert [%{uri: "allbert-memory://stocksage/stocksage"}] = Frame.get_resources(frame)
    assert frame.assigns.public_protocol_client_id == "fixture-client"
  end

  test "Allbert-owned stdio adapter initializes with protocol-only JSON-RPC output" do
    {:ok, [line], state} =
      StdioServer.handle_line(
        ~s({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"fixture-client"}}}\n),
        StdioServer.new_state()
      )

    assert state.initialized?
    assert state.client_id == "fixture-client"

    assert {:ok,
            %{
              "jsonrpc" => "2.0",
              "id" => "init",
              "result" => %{
                "protocolVersion" => "2025-06-18",
                "serverInfo" => %{"name" => "allbert-assist"},
                "capabilities" => %{"tools" => %{}, "resources" => %{}}
              }
            }} = Jason.decode(line)
  end

  test "Allbert-owned stdio adapter lists only Settings-allowlisted tools" do
    enable_mcp_stdio!()
    allow_tools!(["direct_answer"])

    {:ok, [_line], state} =
      StdioServer.handle_line(
        ~s({"jsonrpc":"2.0","id":"init","method":"initialize","params":{"protocolVersion":"2025-06-18"}}\n),
        StdioServer.new_state()
      )

    {:ok, [line], _state} =
      StdioServer.handle_line(
        ~s({"jsonrpc":"2.0","id":"tools","method":"tools/list"}\n),
        state
      )

    assert {:ok, %{"result" => %{"tools" => [%{"name" => "direct_answer"}]}}} =
             Jason.decode(line)
  end

  test "enabled app memory namespaces are exposed as MCP resources" do
    enable_mcp_stdio!()
    allow_namespaces!(["stocksage.stocksage"])

    assert {:ok, [resource]} = Runtime.enabled_resources()
    assert resource.uri == "allbert-memory://stocksage/stocksage"
    assert resource.name == "stocksage.stocksage"

    assert {:ok, payload} = Runtime.read_resource(resource.uri, context())
    assert payload["resource_type"] == "app_memory_namespace"
    assert payload["app_id"] == "stocksage"
    assert payload["namespace"] == "stocksage"
  end

  test "tool call goes through runner and returns redacted MCP payload" do
    enable_mcp_stdio!()
    allow_tools!(["direct_answer"])

    assert {:ok, payload} =
             Runtime.call_tool("direct_answer", %{text: "hello"}, context("fixture-client"))

    assert payload.status == :completed
    assert is_binary(payload.message)
    assert get_in(payload, [:runner_metadata, :action_name]) == "direct_answer"
  end

  test "confirmation-gated tool call creates client-owned public readback id" do
    enable_mcp_stdio!()
    allow_tools!(["external_network_request"])
    enable_external_fixture!()

    assert {:ok, payload} =
             Runtime.call_tool(
               "external_network_request",
               %{url: "https://example.com/"},
               context("fixture-client")
             )

    assert payload.status == "confirmation_pending"
    assert payload.confirmation_id =~ "conf_"
    assert payload.public_call_id =~ "pubcall_"

    assert {:ok, pending} =
             ResultReadback.get_for_client(
               payload.public_call_id,
               "mcp_stdio",
               "fixture-client"
             )

    assert pending.status == :pending
    refute Map.has_key?(pending, :result)

    assert {:ok, 1} =
             ResultReadback.sync_confirmation(%{
               "id" => payload.confirmation_id,
               "status" => "approved",
               "operator_resolution" => %{
                 "target_status" => "completed",
                 "target_result" => %{"message" => "approved result"}
               }
             })

    assert {:ok, approved} =
             ResultReadback.get_for_client(
               payload.public_call_id,
               "mcp_stdio",
               "fixture-client"
             )

    assert approved.status == :approved_with_result
    assert approved.result["message"] == "approved result"
  end

  test "Allbert rejects unsupported MCP protocol versions explicitly" do
    assert ProtocolVersions.supported() == ["2025-06-18", "2025-03-26"]
    assert :ok = Server.validate_protocol_version("2025-06-18")

    assert {:error, error} = Server.validate_protocol_version("2025-11-25")
    assert error.message == "Unsupported MCP protocol version."
    assert error.data.supported == ["2025-06-18", "2025-03-26"]
  end

  test "M3 server code does not configure Hermes StreamableHTTP transport" do
    server_source = File.read!("lib/allbert_assist/public_protocol/mcp/server.ex")
    runtime_source = File.read!("lib/allbert_assist/public_protocol/mcp/runtime.ex")
    task_source = File.read!("lib/mix/tasks/allbert.mcp_server.ex")

    refute server_source =~ "StreamableHTTP"
    refute server_source =~ "transport: :streamable_http"
    refute runtime_source =~ "StreamableHTTP"
    refute runtime_source =~ "Application.get_env"
    refute task_source =~ "Hermes.Server.Supervisor"
  end

  defp enable_mcp_stdio! do
    assert {:ok, _setting} = Settings.put("mcp_server.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("mcp_server.stdio.enabled", true, %{audit?: false})
  end

  defp allow_tools!(tools) do
    assert {:ok, _setting} = Settings.put("mcp_server.tools_enabled", tools, %{audit?: false})
  end

  defp allow_namespaces!(namespaces) do
    assert {:ok, _setting} =
             Settings.put("mcp_server.memory_namespaces_enabled", namespaces, %{audit?: false})
  end

  defp enable_external_fixture! do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_hosts", ["example.com"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/"], %{audit?: false})
  end

  defp context(client_id \\ "stdio-client") do
    %{
      public_protocol: %{surface: "mcp_stdio", client_id: client_id},
      request: %{channel: :mcp_stdio, operator_id: "public-protocol:#{client_id}"}
    }
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
