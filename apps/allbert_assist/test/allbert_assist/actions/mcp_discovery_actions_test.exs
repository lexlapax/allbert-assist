defmodule AllbertAssist.Actions.McpDiscoveryActionsTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Actions.Runner
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
        "allbert-mcp-discovery-actions-#{System.unique_integer([:positive])}"
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

  test "find, fetch manifest, and evaluate actions form the M3 discovery cascade" do
    configure_discovery()
    configure_external("registry.modelcontextprotocol.io", "/v0.1/servers")

    stub_official(
      McpRegistryFixtures.official_response([McpRegistryFixtures.official_shell_risk_server()])
    )

    context = %{actor: "local", channel: :test, external: %{req_plug: {Req.Test, __MODULE__}}}

    assert {:ok, find_response} =
             Runner.run("find_mcp_tools", %{need: "shell", limit: 5}, context)

    assert find_response.status == :completed

    assert [
             %{source: :remote_mcp, usable_now?: false, requires: :connect_confirmation} =
               candidate
           ] =
             find_response.candidates

    assert {:ok, manifest_response} =
             Runner.run("mcp_fetch_server_manifest", %{candidate_id: candidate.id}, context)

    assert manifest_response.status == :completed
    assert manifest_response.manifest["name"] == "io.github.acme/shell-risk"

    assert {:ok, evaluate_response} =
             Runner.run(
               "mcp_evaluate_server",
               %{candidate_id: candidate.id, probe?: false},
               context
             )

    assert evaluate_response.status == :completed
    assert evaluate_response.evaluation_report.provenance_level == "registry_with_source"
    assert evaluate_response.evaluation_report.health_status == "not_probed"

    assert Enum.any?(
             evaluate_response.evaluation_report.dangerous_command_flags,
             &(&1.reason == "remote_script_pipe")
           )
  end

  test "MCP discovery actions are registered with tool-discovery permission" do
    assert {:ok, find_mcp_tools} = Registry.capability("find_mcp_tools")
    assert find_mcp_tools.permission == :tool_discovery
    assert find_mcp_tools.exposure == :agent
    assert find_mcp_tools.execution_mode == :mcp_discovery

    assert {:ok, fetch_manifest} = Registry.capability("mcp_fetch_server_manifest")
    assert fetch_manifest.permission == :tool_discovery
    assert fetch_manifest.execution_mode == :mcp_discovery

    assert {:ok, evaluate_server} = Registry.capability("mcp_evaluate_server")
    assert evaluate_server.permission == :tool_discovery
    assert evaluate_server.execution_mode == :mcp_discovery
  end

  defp stub_official(response) do
    Req.Test.stub(__MODULE__, fn conn ->
      Plug.Conn.send_resp(conn, 200, Jason.encode!(response))
    end)
  end

  defp configure_discovery do
    assert {:ok, _setting} = Settings.put("mcp.discovery.enabled", true, %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.sources.official.enabled", true, %{audit?: false})
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
