defmodule Mix.Tasks.Allbert.McpTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Jobs
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Mcp, as: McpTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-mcp-task-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Mix.Task.reenable("allbert.mcp")

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.mcp")
      File.rm_rf!(root)
    end)

    :ok
  end

  test "discover prints inert results while remote discovery is disabled" do
    output =
      capture_io(fn ->
        assert :ok = McpTask.run(["discover", "github", "--limit", "3"])
      end)

    assert output =~ "Found 0 MCP registry candidate(s)"
    assert output =~ ~s("github")
  end

  test "scan lifecycle commands manage the opt-in discovery job" do
    enable_output =
      capture_io(fn ->
        assert :ok = McpTask.run(["scan", "enable", "--user", "alice"])
      end)

    assert enable_output =~ "Scan enable:"
    assert enable_output =~ "status=paused"

    assert [%{name: "mcp-discovery-scan", user_id: "alice", status: "paused"}] =
             Jobs.list_jobs("alice")

    assert {:ok, _setting} =
             Settings.put("mcp.discovery.scan.schedule", "daily", %{audit?: false})

    resume_output =
      capture_io(fn ->
        assert :ok = McpTask.run(["scan", "resume", "--user", "alice"])
      end)

    assert resume_output =~ "Scan resume:"
    assert resume_output =~ "status=active"

    pause_output =
      capture_io(fn ->
        assert :ok = McpTask.run(["scan", "pause", "--user", "alice"])
      end)

    assert pause_output =~ "Scan pause:"
    assert pause_output =~ "status=paused"
  end

  test "scan run-once fails closed while remote discovery is disabled" do
    assert_raise Mix.Error, ~r/discovery_disabled/, fn ->
      McpTask.run(["scan", "run-once", "weather"])
    end
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
