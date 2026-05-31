defmodule Mix.Tasks.Allbert.McpTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Jobs
  alias AllbertAssist.McpRegistryFixtures
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias AllbertAssist.Tools.Discovery
  alias AllbertAssist.Tools.ToolCandidate
  alias Mix.Tasks.Allbert.Mcp, as: McpTask

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)

    root =
      Path.join(System.tmp_dir!(), "allbert-mcp-task-#{System.unique_integer([:positive])}")

    Application.put_env(:allbert_assist, Paths, home: root)
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Mix.Task.reenable("allbert.mcp")

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      restore_env(Confirmations, original_confirmations_config)
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

  test "connect accepts explicit candidate-id option" do
    {:ok, candidate} = persist_candidate(McpRegistryFixtures.official_shell_risk_server(), "one")

    output =
      capture_io(fn ->
        assert :ok = McpTask.run(["connect", "--candidate-id", candidate.id])
      end)

    assert output =~ "needs connection confirmation"
    assert output =~ "confirmation_id="
  end

  test "connect resolves a unique candidate name" do
    manifest = McpRegistryFixtures.official_shell_risk_server()
    {:ok, _candidate} = persist_candidate(manifest, "unique")

    output =
      capture_io(fn ->
        assert :ok = McpTask.run(["connect", manifest["name"]])
      end)

    assert output =~ "needs connection confirmation"
    assert output =~ "confirmation_id="
  end

  test "connect rejects ambiguous candidate names" do
    manifest = McpRegistryFixtures.official_shell_risk_server()
    {:ok, first} = persist_candidate(manifest, "first")
    {:ok, second} = persist_candidate(manifest, "second")

    error =
      assert_raise Mix.Error, fn ->
        McpTask.run(["connect", manifest["name"]])
      end

    assert Exception.message(error) =~ "ambiguous_candidate_name"
    assert Exception.message(error) =~ first.id
    assert Exception.message(error) =~ second.id
  end

  test "connect resolves exact candidate id before matching names" do
    manifest = McpRegistryFixtures.official_shell_risk_server()
    {:ok, first} = persist_candidate(manifest, "first")
    {:ok, _second} = persist_candidate(manifest, "second")

    output =
      capture_io(fn ->
        assert :ok = McpTask.run(["connect", first.id])
      end)

    assert output =~ "needs connection confirmation"
    assert output =~ "confirmation_id="
  end

  test "connect rejects candidate-id option combined with bare input" do
    {:ok, candidate} = persist_candidate(McpRegistryFixtures.official_shell_risk_server(), "one")

    assert_raise Mix.Error, ~r/Use either --candidate-id or a bare candidate id/, fn ->
      McpTask.run(["connect", "--candidate-id", candidate.id, "io.github.acme/shell-risk"])
    end
  end

  defp persist_candidate(manifest, suffix) do
    {:ok, candidate} =
      ToolCandidate.normalize(%{
        id: "remote_mcp:official:#{suffix}",
        name: manifest["name"],
        description: manifest["description"],
        source: :remote_mcp,
        provenance: %{provider: :official, remote_server_id: "#{manifest["name"]}:#{suffix}"}
      })

    assert {:ok, _record} = Discovery.upsert_candidate(candidate, %{registry_record: manifest})
    {:ok, candidate}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
