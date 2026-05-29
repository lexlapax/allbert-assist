defmodule Mix.Tasks.Allbert.PackagesTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Confirmations, as: ConfirmationsTask
  alias Mix.Tasks.Allbert.Packages, as: PackagesTask

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-packages-task-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    fake_npm = Path.join(root, "fake-npm")
    File.mkdir_p!(workspace)
    write_fake_npm!(fake_npm)

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(root, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(
      :allbert_assist,
      Paths,
      Keyword.merge(original_paths_config || [],
        package_installs_root: Path.join(root, "package-installs")
      )
    )

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Settings, original_settings_config)
      restore_env(Paths, original_paths_config)
      Mix.Task.reenable("allbert.packages")
      Mix.Task.reenable("allbert.confirmations")
      File.rm_rf!(root)
    end)

    put_package_policy!(workspace, fake_npm)

    {:ok, workspace: workspace}
  end

  test "plans, requests, approves, and lists package install metadata", %{workspace: workspace} do
    plan_output =
      capture_io(fn ->
        assert :ok =
                 PackagesTask.run([
                   "plan",
                   "npm",
                   "--cwd",
                   workspace,
                   "--package",
                   "left-pad@1.3.0"
                 ])
      end)

    assert plan_output =~ "Status: completed"
    assert plan_output =~ "Dry-run argv: "
    assert plan_output =~ "--dry-run"
    assert plan_output =~ "--allow-git=none"

    Mix.Task.reenable("allbert.packages")

    request_output =
      capture_io(fn ->
        assert :ok =
                 PackagesTask.run([
                   "run",
                   "npm",
                   "--cwd",
                   workspace,
                   "--package",
                   "left-pad@1.3.0"
                 ])
      end)

    assert request_output =~ "Status: needs_confirmation"
    assert request_output =~ "Confirmation: conf_"
    assert request_output =~ "Execution argv: "

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "run_package_install"

    approve_output =
      capture_io(fn ->
        assert :ok =
                 ConfirmationsTask.run(["approve", pending["id"], "--reason", "package smoke"])
      end)

    assert approve_output =~ "#{pending["id"]} status=approved"
    assert approve_output =~ "Manager: npm"
    assert approve_output =~ "Packages: left-pad@1.3.0"
    assert approve_output =~ "Result: completed"
    assert approve_output =~ "Output preview:"
    assert approve_output =~ "fake npm install left-pad@1.3.0"

    Mix.Task.reenable("allbert.confirmations")

    resolved_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["list", "--resolved"])
      end)

    assert resolved_output =~ "#{pending["id"]} status=approved"
    assert resolved_output =~ "Execution argv:"
    assert resolved_output =~ "fake npm install left-pad@1.3.0"
  end

  defp put_package_policy!(workspace, fake_npm) do
    settings = %{
      "permissions" => %{"package_install" => "allowed"},
      "package_installs" => %{
        "enabled" => true,
        "allowed_roots" => [workspace],
        "allowed_managers" => ["npm"],
        "manager_profiles" => %{
          "npm" => %{"executable" => fake_npm}
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp write_fake_npm!(path) do
    File.write!(path, "#!/bin/sh\nprintf 'fake npm %s\\n' \"$*\"\n")
    File.chmod!(path, 0o755)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
