defmodule AllbertAssist.Actions.ToolsActionsTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {Req.Test, :verify_on_exit!}

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-tools-actions-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    {:ok, call_log} = Agent.start_link(fn -> [] end)

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root, call_log: call_log}
  end

  test "find_local_tools returns usable local candidates" do
    context = %{actor: "local", channel: :test, include_configured_mcp?: false}

    assert {:ok, response} = Runner.run("find_local_tools", %{query: "settings"}, context)

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed

    assert Enum.any?(
             response.candidates,
             &(&1.source == :local_action and &1.name == "list_settings")
           )

    assert Enum.all?(response.candidates, & &1.usable_now?)
    assert Enum.all?(response.candidates, &(&1.requires == :none))
  end

  test "find_tools orchestrates the local source in M2" do
    context = %{actor: "local", channel: :test, include_configured_mcp?: false}

    assert {:ok, response} = Runner.run("find_tools", %{query: "settings"}, context)

    assert response.status == :completed
    assert response.diagnostics == []

    assert Enum.any?(
             response.candidates,
             &(&1.source == :local_action and &1.name == "list_settings")
           )
  end

  test "find tool actions accept need as a query alias" do
    context = %{actor: "local", channel: :test, include_configured_mcp?: false}

    assert {:ok, local_response} = Runner.run("find_local_tools", %{need: "settings"}, context)
    assert {:ok, unified_response} = Runner.run("find_tools", %{need: "settings"}, context)

    assert local_response.status == :completed
    assert unified_response.status == :completed

    assert Enum.any?(
             local_response.candidates,
             &(&1.source == :local_action and &1.name == "list_settings")
           )

    assert Enum.any?(
             unified_response.candidates,
             &(&1.source == :local_action and &1.name == "list_settings")
           )
  end

  test "find_tools skips remote registry when tool discovery is denied", %{call_log: call_log} do
    configure_discovery()
    configure_registry_external()
    deny_tool_discovery()
    stub_registry(call_log)

    context = %{
      actor: "local",
      channel: :test,
      external: %{req_plug: {Req.Test, __MODULE__}},
      include_configured_mcp?: false
    }

    assert {:ok, response} = Runner.run("find_tools", %{query: "settings", limit: 10}, context)

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed
    assert Agent.get(call_log, & &1) == []

    assert Enum.any?(
             response.candidates,
             &(&1.source == :local_action and &1.name == "list_settings")
           )

    assert Enum.any?(
             response.diagnostics,
             &(&1.source == :mcp_registry and &1.status == :denied and
                 &1.reason == ":tool_discovery denied")
           )
  end

  test "tool discovery actions are registered as internal MCP discovery capabilities" do
    assert {:ok, find_local_tools} = Registry.capability("find_local_tools")
    assert find_local_tools.permission == :read_only
    assert find_local_tools.exposure == :internal
    assert find_local_tools.execution_mode == :mcp_discovery

    assert {:ok, find_tools} = Registry.capability("find_tools")
    assert find_tools.permission == :read_only
    assert find_tools.exposure == :internal
    assert find_tools.execution_mode == :mcp_discovery
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)

  defp configure_discovery do
    assert {:ok, _setting} = Settings.put("mcp.discovery.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.sources.official.enabled", true, %{audit?: false})
  end

  defp configure_registry_external do
    assert {:ok, _setting} = Settings.put("external_services.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "external_services.allowed_hosts",
               ["registry.modelcontextprotocol.io"],
               %{audit?: false}
             )

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_paths", ["/v0.1/servers"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("external_services.allowed_methods", ["GET"], %{audit?: false})
  end

  defp deny_tool_discovery do
    assert {:ok, _setting} =
             Settings.put("permissions.tool_discovery", "denied", %{audit?: false})
  end

  defp stub_registry(call_log) do
    Req.Test.stub(__MODULE__, fn conn ->
      Agent.update(call_log, &(&1 ++ [{conn.method, conn.request_path}]))
      Plug.Conn.send_resp(conn, 200, Jason.encode!(%{"servers" => []}))
    end)
  end
end
