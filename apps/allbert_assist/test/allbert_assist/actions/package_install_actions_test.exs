defmodule AllbertAssist.Actions.PackageInstallActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Packages.Audit
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Settings

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-package-actions-#{System.unique_integer([:positive])}"
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
      File.rm_rf!(root)
    end)

    put_package_policy!(workspace, fake_npm)

    {:ok, root: root, workspace: workspace, fake_npm: fake_npm}
  end

  test "plans package installs without creating confirmations", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run(
               "plan_package_install",
               %{manager: "npm", package: "left-pad@1.3.0", project_root: workspace},
               context()
             )

    assert response.status == :completed
    assert response.message =~ "Package install planned, not executed"
    assert response.install_plan.execution_available?
    assert response.install_plan.dry_run_argv |> Enum.join(" ") =~ "--dry-run"
    assert Confirmations.list(status: :pending) == []
  end

  test "creates confirmation and approval resumes npm execution", %{workspace: workspace} do
    assert {:ok, pending_response} =
             Runner.run(
               "run_package_install",
               %{manager: "npm", package: "left-pad@1.3.0", project_root: workspace},
               context()
             )

    assert pending_response.status == :needs_confirmation
    assert pending_response.permission_decision.decision == :needs_confirmation
    assert pending_response.message =~ "Nothing has executed yet"
    assert pending_response.confirmation_id =~ "conf_"

    assert {:ok, pending} = Confirmations.read(pending_response.confirmation_id)
    assert pending["target_action"]["name"] == "run_package_install"
    assert pending["target_permission"] == "package_install"
    assert pending["target_execution_mode"] == "package_manager_process"
    assert pending["params_summary"]["packages"] == ["left-pad@1.3.0"]

    assert pending["params_summary"]["execution_argv_preview"] |> Enum.join(" ") =~
             "--allow-git=none"

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{id: pending_response.confirmation_id, reason: "package smoke"},
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.status == :completed
    assert approve_response.confirmation["status"] == "approved"
    assert approve_response.confirmation["operator_resolution"]["target_resumed?"]
    assert approve_response.confirmation["operator_resolution"]["target_status"] == "completed"

    target_result = approve_response.confirmation["operator_resolution"]["target_result"]
    assert target_result["stdout_preview"] =~ "fake npm install left-pad@1.3.0"
    assert target_result["stdout_preview"] =~ "--ignore-scripts"
    assert target_result["stdout_preview"] =~ "--allow-git=none"

    audit = package_audit()
    assert audit =~ "event: requested"
    assert audit =~ "event: approved"
    assert audit =~ "event: succeeded"
    assert audit =~ "left-pad@1.3.0"
  end

  test "approval can remember all package-install refs and later skip confirmation", %{
    workspace: workspace
  } do
    assert {:ok, pending_response} =
             Runner.run(
               "run_package_install",
               %{manager: "npm", package: "left-pad@1.3.0", project_root: workspace},
               context()
             )

    assert {:ok, approve_response} =
             Runner.run(
               "approve_confirmation",
               %{
                 id: pending_response.confirmation_id,
                 reason: "remember package refs",
                 remember_scope: "exact",
                 remember_all: true
               },
               %{actor: "local", channel: :cli, surface: "mix allbert.confirmations"}
             )

    assert approve_response.confirmation["status"] == "approved"
    assert remembered = approve_response.confirmation["operator_resolution"]["remembered_grants"]
    assert length(remembered) == 2
    assert Enum.any?(remembered, &(&1["origin_kind"] == "package_registry"))
    assert Enum.any?(remembered, &(&1["origin_kind"] == "local_path"))

    assert {:ok, reused_response} =
             Runner.run(
               "run_package_install",
               %{manager: "npm", package: "left-pad@1.3.0", project_root: workspace},
               context()
             )

    assert reused_response.status == :completed
    assert reused_response.result.stdout_preview =~ "fake npm install left-pad@1.3.0"
    assert reused_response.actions |> hd() |> get_in([:resource_grants, :applied?])
    assert reused_response.actions |> hd() |> get_in([:target_resumed?]) == false
    assert Confirmations.list(status: :pending) == []
  end

  test "target-root grant alone does not authorize package registry drift", %{
    workspace: workspace
  } do
    assert {:ok, pending_response} =
             Runner.run(
               "run_package_install",
               %{manager: "npm", package: "left-pad@1.3.0", project_root: workspace},
               context()
             )

    assert {:ok, pending} = Confirmations.read(pending_response.confirmation_id)

    [target_root_ref] =
      Enum.filter(
        pending["params_summary"]["resource_refs"],
        &(&1["origin_kind"] == "local_path")
      )

    assert {:ok, _grant} = Grants.remember(target_root_ref, audit?: false)

    assert {:ok, later_response} =
             Runner.run(
               "run_package_install",
               %{manager: "npm", package: "left-pad@1.3.0", project_root: workspace},
               context()
             )

    assert later_response.status == :needs_confirmation
    assert later_response.confirmation_id != pending_response.confirmation_id
    assert length(Confirmations.list(status: :pending)) == 2
  end

  test "denies pip execution as preview-only", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run(
               "run_package_install",
               %{manager: "pip", package: "requests==2.31.0", project_root: workspace},
               context()
             )

    assert response.status == :denied
    assert response.message =~ "pip execution requires strict hash and binary policy"
    assert Confirmations.list(status: :pending) == []
  end

  defp context do
    %{
      actor: "local",
      channel: :cli,
      surface: "mix allbert.packages",
      request: %{operator_id: "local", channel: :cli, input_signal_id: "sig-package"}
    }
  end

  defp put_package_policy!(workspace, fake_npm) do
    settings = %{
      "permissions" => %{"package_install" => "allowed"},
      "package_installs" => %{
        "enabled" => true,
        "allowed_roots" => [workspace],
        "allowed_managers" => ["npm", "pip"],
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

  defp package_audit do
    [path] = Path.wildcard(Path.join([Audit.audit_root(), "*.md"]))
    File.read!(path)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
