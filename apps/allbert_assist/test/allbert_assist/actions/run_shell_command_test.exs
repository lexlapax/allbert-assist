defmodule AllbertAssist.Actions.RunShellCommandTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Settings

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-run-shell-command-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "fixture\n")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))
    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    put_execution_policy!(workspace)

    {:ok, root: root, workspace: workspace}
  end

  test "denies disallowed command specs without creating confirmation", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run(
               "run_shell_command",
               %{executable: "curl", args: ["https://example.com"], cwd: workspace},
               context()
             )

    assert response.status == :denied
    assert response.command.denial_reason == :network_command_not_allowed
    assert response.actions |> hd() |> Map.fetch!(:execution) == :not_started
    assert Confirmations.list(status: :pending) == []
  end

  test "creates pending confirmation for an allowed local command", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run(
               "run_shell_command",
               %{executable: "ls", args: ["-la"], cwd: workspace},
               context()
             )

    assert response.status == :needs_confirmation
    assert response.permission_decision.decision == :needs_confirmation
    assert response.message =~ "Nothing has executed yet"
    assert response.confirmation_id =~ "conf_"
    assert response.command.executable == "ls"
    assert response.command.policy_decision == :allowed

    assert {:ok, pending} = Confirmations.read(response.confirmation_id)
    assert pending["status"] == "pending"
    assert pending["target_action"]["name"] == "run_shell_command"
    assert pending["target_permission"] == "command_execute"
    assert pending["target_execution_mode"] == "local_process"
    assert pending["params_summary"]["policy_decision"] == "allowed"
  end

  test "approval resumes a pending shell command once", %{workspace: workspace} do
    assert {:ok, pending_response} =
             Runner.run(
               "run_shell_command",
               %{executable: "pwd", args: [], cwd: workspace},
               context()
             )

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_response.confirmation_id, reason: "approved for smoke test"},
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.status == :completed
    assert approve_response.confirmation["status"] == "approved"
    assert approve_response.confirmation["operator_resolution"]["target_resumed?"]
    assert approve_response.confirmation["operator_resolution"]["target_status"] == "completed"

    approval_action = hd(approve_response.actions)
    assert approval_action.confirmation_metadata.target_resumed?
    assert approval_action.confirmation_metadata.target_status == :completed
    assert approval_action.confirmation_metadata.target_result.status == :completed
    assert approval_action.confirmation_metadata.target_result.stdout_preview =~ workspace

    assert {:ok, approve_again} =
             Runner.run("approve_confirmation", %{id: pending_response.confirmation_id}, %{
               actor: "local",
               channel: :cli
             })

    assert approve_again.status == :completed
    assert approve_again.confirmation["status"] == "approved"
    assert approve_again.actions |> hd() |> get_in([:confirmation_metadata, :idempotent?])
  end

  test "approval re-check denies stale command execution policy", %{workspace: workspace} do
    assert {:ok, pending_response} =
             Runner.run(
               "run_shell_command",
               %{executable: "pwd", args: [], cwd: workspace},
               context()
             )

    assert {:ok, _setting} =
             Settings.put("permissions.command_execute", "denied", %{audit?: false})

    assert {:ok, approve_response} =
             Runner.run("approve_confirmation", %{id: pending_response.confirmation_id}, %{
               actor: "local",
               channel: :cli
             })

    assert approve_response.status == :completed
    assert approve_response.confirmation["status"] == "denied"

    assert approve_response.actions
           |> hd()
           |> get_in([:confirmation_metadata, :blocked_by_policy?])

    assert approve_response.actions |> hd() |> get_in([:confirmation_metadata, :target_resumed?]) ==
             false
  end

  defp context do
    %{
      actor: "local",
      channel: :cli,
      surface: "mix allbert.exec",
      request: %{operator_id: "local", channel: :cli, input_signal_id: "sig-shell"}
    }
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
