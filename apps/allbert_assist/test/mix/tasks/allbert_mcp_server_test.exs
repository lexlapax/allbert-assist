defmodule Mix.Tasks.AllbertMcpServerTest do
  use AllbertAssist.DataCase, async: false, lane: :external_runtime_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.McpServer

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-server-task-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Mix.Task.reenable("allbert.mcp_server")

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
      Mix.Task.reenable("allbert.mcp_server")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "status reports settings-central state and Allbert-owned HTTP ingress posture" do
    output =
      capture_io(fn ->
        assert :ok = McpServer.run(["status"])
      end)

    assert output =~ "mcp_server.enabled=false"
    assert output =~ "mcp_stdio.enabled=false"
    assert output =~ "mcp_protocol_versions=2025-06-18,2025-03-26"
    assert output =~ "mcp_http_transport=allbert_owned_ingress_only"
  end

  test "tools list prints only settings-allowlisted tools" do
    enable_mcp_stdio!()

    assert {:ok, _setting} =
             Settings.put("mcp_server.tools_enabled", ["direct_answer"], %{audit?: false})

    output =
      capture_io(fn ->
        assert :ok = McpServer.run(["tools", "list"])
      end)

    assert output =~ "direct_answer"
    refute output =~ "list_settings"
  end

  test "resources list prints only settings-allowlisted app namespaces" do
    enable_mcp_stdio!()

    assert {:ok, _setting} =
             Settings.put("mcp_server.memory_namespaces_enabled", ["stocksage.stocksage"], %{
               audit?: false
             })

    output =
      capture_io(fn ->
        assert :ok = McpServer.run(["resources", "list"])
      end)

    assert output =~ "allbert-memory://stocksage/stocksage"
    refute output =~ "identity"
  end

  defp enable_mcp_stdio! do
    assert {:ok, _setting} = Settings.put("mcp_server.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("mcp_server.stdio.enabled", true, %{audit?: false})
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
