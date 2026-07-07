defmodule AllbertAssist.Actions.Mcp.ScanActionsTest do
  @moduledoc """
  v0.62 M8.19: MCP discovery scan lifecycle commands run on-spine through Runner.
  """
  use AllbertAssist.DataCase, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Jobs
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    home =
      Path.join(
        System.tmp_dir!(),
        "allbert-mcp-scan-actions-#{System.unique_integer([:positive])}"
      )

    Application.put_env(:allbert_assist, Paths, home: home)
    Application.put_env(:allbert_assist, Settings, root: Path.join(home, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths)
      restore_env(Settings, original_settings)
      File.rm_rf!(home)
    end)

    :ok
  end

  test "enable, pause, and resume mutate the managed scan job through registered actions" do
    ctx = ctx("operator")

    assert {:ok, enable} = Runner.run("mcp_scan_enable", %{user_id: "alice"}, ctx)
    assert enable.status == :completed
    assert enable.permission_decision.permission == :settings_write
    assert enable.scan_job.user_id == "alice"
    assert enable.scan_job.status == "paused"
    assert action_name(enable) == "mcp_scan_enable"

    assert [%{name: "mcp-discovery-scan", user_id: "alice", status: "paused"}] =
             Jobs.list_jobs("alice")

    assert {:ok, resume} = Runner.run("mcp_scan_resume", %{user_id: "alice"}, ctx)
    assert resume.status == :completed
    assert resume.permission_decision.permission == :job_write
    assert resume.scan_job.status == "active"
    assert action_name(resume) == "mcp_scan_resume"

    assert {:ok, pause} = Runner.run("mcp_scan_pause", %{user_id: "alice"}, ctx)
    assert pause.status == :completed
    assert pause.scan_job.status == "paused"
    assert action_name(pause) == "mcp_scan_pause"
  end

  test "run-once fails closed through the action while discovery is disabled" do
    assert {:ok, response} = Runner.run("mcp_scan_run_once", %{query: "weather"}, ctx("local"))

    assert response.status == :failed
    assert response.error == :discovery_disabled
    assert response.permission_decision.permission == :job_write
    assert action_name(response) == "mcp_scan_run_once"
  end

  defp action_name(%{actions: [action]}), do: action.name

  defp ctx(user_id), do: %{actor: user_id, user_id: user_id, channel: :cli}

  defp restore_env(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
