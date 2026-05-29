defmodule AllbertAssist.Actions.McpActionsTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Resources.ResourceURI
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Secrets

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(System.tmp_dir!(), "allbert-mcp-actions-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    {:ok, _log} = Agent.start(fn -> [] end, name: __MODULE__.CallLog)
    configure_external()
    configure_http_server()
    stub_http_mcp()

    on_exit(fn ->
      if Process.whereis(__MODULE__.CallLog), do: safe_stop_call_log()
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
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

  test "mcp_call_tool confirms before transport and redacts tool I/O", %{root: root} do
    context = %{actor: "local", channel: :test, mcp: %{req_plug: {Req.Test, __MODULE__}}}
    arguments = %{"text" => "secret input"}
    tool_uri = ResourceURI.mcp!("demo", "tools/search")

    assert {:ok, pending} =
             Runner.run(
               "mcp_call_tool",
               %{server_id: "demo", tool_name: "search", arguments: arguments},
               context
             )

    assert pending.status == :needs_confirmation
    assert Agent.get(__MODULE__.CallLog, & &1) == []
    assert pending.tool_call.arguments == %{key_count: 1, keys: ["text"]}
    refute inspect(pending.confirmation["params_summary"]) =~ "secret input"
    assert [ref] = pending.confirmation["params_summary"]["resource_refs"]
    assert ref["resource_uri"] == tool_uri
    assert ref["operation_class"] == "mcp_tool_call"

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "ok"},
               context
             )

    assert approved.status == :completed
    assert get_in(approved.confirmation, ["operator_resolution", "target_resumed?"])
    assert get_in(approved.confirmation, ["operator_resolution", "target_status"]) == "completed"

    assert get_in(approved.confirmation, ["operator_resolution", "target_result", "result_keys"]) ==
             ["content"]

    assert Agent.get(__MODULE__.CallLog, & &1) == ["initialize", "tools/call"]

    audit = File.read!(Path.join([root, "mcp", "audit", audit_file()]))
    assert audit =~ "mcp_call_tool"
    assert audit =~ "tool_name: search"
    refute audit =~ "secret input"
    refute audit =~ "secret output"
    refute audit =~ "secret-token"
  end

  test "mcp_call_tool denylist and allowlist block before transport" do
    context = %{actor: "local", channel: :test, mcp: %{req_plug: {Req.Test, __MODULE__}}}

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.tool_denylist", ["danger"], %{audit?: false})

    assert {:ok, denied} =
             Runner.run(
               "mcp_call_tool",
               %{server_id: "demo", tool_name: "danger", arguments: %{}},
               context
             )

    assert denied.status == :denied
    assert denied.error == :tool_denied

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.tool_denylist", [], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.demo.tool_allowlist", ["search"], %{audit?: false})

    assert {:ok, not_allowed} =
             Runner.run(
               "mcp_call_tool",
               %{server_id: "demo", tool_name: "echo", arguments: %{}},
               context
             )

    assert not_allowed.status == :denied
    assert not_allowed.error == :tool_not_allowed
    assert Agent.get(__MODULE__.CallLog, & &1) == []
  end

  test "mcp_call_tool disabled server blocks before transport" do
    context = %{actor: "local", channel: :test, mcp: %{req_plug: {Req.Test, __MODULE__}}}

    assert {:ok, _setting} = Settings.put("mcp.servers.demo.enabled", false, %{audit?: false})

    assert {:ok, denied} =
             Runner.run(
               "mcp_call_tool",
               %{server_id: "demo", tool_name: "search", arguments: %{}},
               context
             )

    assert denied.status == :denied
    assert denied.error == :server_disabled
    assert Agent.get(__MODULE__.CallLog, & &1) == []
  end

  test "mcp_call_tool executes a valid call over real stdio transport after approval", %{
    root: root
  } do
    script = Path.join(root, "mock_mcp_tool_stdio.exs")
    log_path = Path.join(root, "stdio-tool-call.log")

    File.write!(script, """
    log_path = System.get_env("MCP_CALL_LOG")
    IO.puts(:stderr, "mock MCP stderr startup log")

    for line <- IO.stream(:stdio, :line) do
      id_token =
        case Regex.run(~r/"id"\\s*:\\s*("[^"]+"|[0-9]+)/, line) do
          [_, token] -> token
          _other -> "null"
        end

      method =
        case Regex.run(~r/"method"\\s*:\\s*"([^"]+)"/, line) do
          [_, value] -> value
          _other -> "unknown"
        end

      if log_path, do: File.write!(log_path, method <> "\\n", [:append])
      IO.puts(:stderr, "mock MCP stderr request log: " <> method)

      result =
        case method do
          "initialize" ->
            ~s({"protocolVersion":"2025-03-26","capabilities":{}})

          "tools/call" ->
            ~s({"content":[{"type":"text","text":"stdio pong"}]})

          _other ->
            ~s({})
        end

      IO.puts(~s({"jsonrpc":"2.0","id":\#{id_token},"result":\#{result}}))
    end
    """)

    configure_stdio_tool_server(script, log_path)
    context = %{actor: "local", channel: :test}

    assert {:ok, pending} =
             Runner.run(
               "mcp_call_tool",
               %{server_id: "stdio_tool", tool_name: "ping", arguments: %{"message" => "hello"}},
               context
             )

    assert pending.status == :needs_confirmation
    refute File.exists?(log_path)

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "valid stdio tool call"},
               context
             )

    assert get_in(approved.confirmation, ["operator_resolution", "target_status"]) == "completed"

    assert get_in(approved.confirmation, [
             "operator_resolution",
             "target_result",
             "result_keys"
           ]) == ["content"]

    assert File.read!(log_path) == "initialize\nnotifications/initialized\ntools/call\n"
    refute inspect(approved) =~ "stdio pong"
  end

  test "mcp_read_resource requires a Resource Access grant, then reuses it", %{root: root} do
    context = %{actor: "local", channel: :test, mcp: %{req_plug: {Req.Test, __MODULE__}}}
    server_uri = "file:///demo.md"
    canonical_uri = ResourceURI.mcp!("demo", server_uri)

    assert {:ok, pending} =
             Runner.run("mcp_read_resource", %{server_id: "demo", uri: server_uri}, context)

    assert pending.status == :needs_confirmation
    assert pending.resource.resource_uri == canonical_uri
    assert [ref] = pending.confirmation["params_summary"]["resource_refs"]
    assert ref["resource_uri"] == canonical_uri
    assert ref["origin_kind"] == "mcp_resource"
    assert ref["operation_class"] == "mcp_resource_read"

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, remember_scope: "mcp_server", reason: "ok"},
               context
             )

    assert approved.status == :completed
    assert get_in(approved.confirmation, ["operator_resolution", "target_resumed?"])
    assert get_in(approved.confirmation, ["operator_resolution", "target_status"]) == "completed"
    assert {:ok, [%{"scope" => %{"kind" => "mcp_server"}}]} = Grants.list()

    assert {:ok, completed} =
             Runner.run("mcp_read_resource", %{server_id: "demo", uri: server_uri}, context)

    assert completed.status == :completed
    assert completed.resource.resource_uri == canonical_uri
    assert [%{"text_preview" => "hello from mcp"}] = completed.resource.contents

    audit = File.read!(Path.join([root, "mcp", "audit", audit_file()]))
    assert audit =~ "mcp_read_resource"
    assert audit =~ canonical_uri
    refute audit =~ "hello from mcp"
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

  defp configure_stdio_tool_server(script, log_path) do
    assert {:ok, _setting} =
             Settings.put("mcp.stdio.allowed_launchers", ["elixir"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_tool.enabled", false, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_tool.transport", "stdio", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_tool.command", "elixir", %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_tool.args", [script], %{audit?: false})

    assert {:ok, _secret} =
             Secrets.put_secret("secret://mcp/stdio_tool/log_path", log_path, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "mcp.servers.stdio_tool.env",
               %{"MCP_CALL_LOG" => "secret://mcp/stdio_tool/log_path"},
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("mcp.servers.stdio_tool.enabled", true, %{audit?: false})
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
      Agent.update(__MODULE__.CallLog, &(&1 ++ [request["method"]]))

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

          "resources/read" ->
            %{
              "contents" => [
                %{
                  "uri" => request["params"]["uri"],
                  "mimeType" => "text/plain",
                  "text" => "hello from mcp"
                }
              ]
            }

          "tools/call" ->
            %{
              "content" => [
                %{"type" => "text", "text" => "secret output"}
              ]
            }
        end

      response = Jason.encode!(%{"jsonrpc" => "2.0", "id" => request["id"], "result" => result})

      Plug.Conn.send_resp(conn, 200, response)
    end)
  end

  defp audit_file do
    DateTime.utc_now()
    |> Calendar.strftime("%Y-%m.md")
  end

  defp safe_stop_call_log do
    Agent.stop(__MODULE__.CallLog)
  catch
    :exit, _reason -> :ok
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
