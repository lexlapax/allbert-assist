defmodule AllbertAssist.Execution.LocalRunnerTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.LocalRunner
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-execution-local-runner-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "fixture\n")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    put_execution_policy!(workspace)

    {:ok, root: root, workspace: workspace}
  end

  test "runs an allowed local command in the approved cwd", %{workspace: workspace} do
    assert {:ok, spec} = allowed_spec("pwd", [], workspace)
    assert {:ok, result} = LocalRunner.run(spec)

    assert result.status == :completed
    assert result.exit_status == 0
    assert result.stdout =~ workspace
    assert result.stderr == ""
    assert result.stderr_merged?
    assert result.command.resolved_cwd == Path.expand(workspace)
  end

  test "captures non-zero exit output without leaking to terminal", %{workspace: workspace} do
    assert {:ok, spec} = allowed_spec("ls", ["--allbert-not-a-real-option"], workspace)
    assert {:ok, result} = LocalRunner.run(spec)

    assert result.status == :completed
    assert result.exit_status != 0
    assert result.stdout != ""
    assert result.stderr_merged?
  end

  test "enforces output cap", %{workspace: workspace} do
    Enum.each(1..20, fn index ->
      File.write!(Path.join(workspace, "file-#{index}.txt"), "x\n")
    end)

    assert {:ok, spec} =
             CommandSpec.normalize(%{
               executable: "ls",
               args: [],
               cwd: workspace,
               max_output_bytes: 12
             })

    assert {:ok, result} = LocalRunner.run(spec)

    assert result.status == :completed
    assert result.truncated?
    assert result.output_bytes == 12
    assert [%{reason: :output_truncated, max_output_bytes: 12}] = result.diagnostics
  end

  test "enforces timeout", %{workspace: workspace} do
    put_execution_policy!(workspace, %{
      "sleep_short" => %{
        "command" => "sleep",
        "args_prefix" => ["2"],
        "command_class" => "developer",
        "timeout_ms" => 1000,
        "max_output_bytes" => 1024
      }
    })

    assert {:ok, spec} =
             CommandSpec.normalize(%{
               executable: "sleep",
               args: ["2"],
               cwd: workspace
             })

    assert {:ok, result} = LocalRunner.run(spec)

    assert result.status == :timed_out
    assert result.timed_out?
    assert [%{reason: :timeout, timeout_ms: 1000}] = result.diagnostics
  end

  test "does not use shell expansion", %{workspace: workspace} do
    File.write!(Path.join(workspace, "*"), "star\n")
    File.write!(Path.join(workspace, "regular"), "regular\n")

    assert {:ok, spec} = allowed_spec("ls", ["*"], workspace)
    assert {:ok, result} = LocalRunner.run(spec)

    assert result.status == :completed
    assert result.exit_status == 0
    assert String.trim(result.stdout) == "*"
  end

  test "refuses to run denied specs", %{workspace: workspace} do
    assert {:error, denied_spec} =
             CommandSpec.normalize(%{
               executable: "curl",
               args: ["https://example.com"],
               cwd: workspace
             })

    assert {:ok, result} = LocalRunner.run(denied_spec)

    assert result.status == :denied
    assert result.exit_status == nil
    assert [%{reason: :network_command_not_allowed}] = result.diagnostics
  end

  defp allowed_spec(executable, args, workspace) do
    CommandSpec.normalize(%{executable: executable, args: args, cwd: workspace})
  end

  defp put_execution_policy!(workspace, profiles \\ %{}) do
    settings = %{
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [workspace],
          "command_profiles" => profiles
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
