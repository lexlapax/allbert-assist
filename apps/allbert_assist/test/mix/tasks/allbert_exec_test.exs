defmodule Mix.Tasks.Allbert.ExecTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Confirmations, as: ConfirmationsTask
  alias Mix.Tasks.Allbert.Exec, as: ExecTask

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-exec-task-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "exec fixture\n")

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.exec")
      Mix.Task.reenable("allbert.confirmations")
      File.rm_rf!(root)
    end)

    put_execution_policy!(workspace)

    {:ok, root: root, workspace: workspace}
  end

  test "requests and approves an allowed local command", %{workspace: workspace} do
    request_output =
      capture_io(fn ->
        assert :ok = ExecTask.run(["--cwd", workspace, "--", "ls", "-la"])
      end)

    assert request_output =~ "Status: needs_confirmation"
    assert request_output =~ "Confirmation: conf_"
    assert request_output =~ "Command: ls -la"
    assert request_output =~ "Cwd: #{workspace}"
    assert request_output =~ "Sandbox: level 1"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "run_shell_command"

    approve_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["approve", pending["id"], "--reason", "smoke"])
      end)

    assert approve_output =~ "#{pending["id"]} status=approved"
    assert approve_output =~ "Command: ls -la"
    assert approve_output =~ "Result: completed"
    assert approve_output =~ "Exit: 0"
    assert approve_output =~ "Output preview:"
    assert approve_output =~ "README.md"

    resolved_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["list", "--resolved"])
      end)

    assert resolved_output =~ "#{pending["id"]} status=approved"
    assert resolved_output =~ "Command: ls -la"
    assert resolved_output =~ "Output preview:"
  end

  test "prints policy denials without creating confirmations", %{workspace: workspace} do
    out_of_root_output =
      capture_io(fn ->
        assert :ok = ExecTask.run(["--cwd", workspace, "--", "ls", "-la", "/etc"])
      end)

    assert out_of_root_output =~ "Status: denied"
    assert out_of_root_output =~ "path_operands_outside_allowed_roots"

    network_output =
      capture_io(fn ->
        assert :ok = ExecTask.run(["--cwd", workspace, "--", "curl", "https://example.com"])
      end)

    assert network_output =~ "Status: denied"
    assert network_output =~ "network_command_not_allowed"
    assert Confirmations.list(status: :pending) == []
  end

  defp put_execution_policy!(workspace) do
    settings = %{
      "permissions" => %{"command_execute" => "allowed"},
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [workspace]
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
