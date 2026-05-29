defmodule AllbertAssist.Packages.InstallSpecTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Packages.InstallSpec
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-install-spec-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    Application.put_env(
      :allbert_assist,
      Paths,
      Keyword.merge(original_paths_config || [],
        package_installs_root: Path.join(root, "package-installs")
      )
    )

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      restore_env(Paths, original_paths_config)
      File.rm_rf!(root)
    end)

    put_package_policy!(workspace)

    {:ok, root: root, workspace: workspace}
  end

  test "normalizes pinned npm specs into dry-run and execution argv", %{workspace: workspace} do
    assert {:ok, spec} =
             InstallSpec.normalize(%{
               manager: "npm",
               package: "left-pad@1.3.0",
               project_root: workspace,
               save_mode: "dev"
             })

    assert spec.policy_decision == :allowed
    assert spec.execution_available?

    assert spec.packages == [
             %{manager: :npm, name: "left-pad", version: "1.3.0", spec: "left-pad@1.3.0"}
           ]

    assert spec.save_mode == :dev
    assert "--dry-run" in spec.dry_run_args
    assert "--json" in spec.dry_run_args
    assert "--ignore-scripts" in spec.install_args
    assert "--allow-git=none" in spec.install_args
    assert "--save-dev" in spec.install_args
    refute "--global" in spec.install_args

    summary = InstallSpec.summary(spec)
    assert summary.execution_argv_preview == ["npm" | spec.install_args]
    assert summary.resolved_target_root == workspace
  end

  test "applies a separate version field to an unpinned npm package", %{workspace: workspace} do
    assert {:ok, spec} =
             InstallSpec.normalize(%{
               manager: "npm",
               package: "@scope/tool",
               version: "2.1.0",
               cwd: workspace
             })

    assert [%{spec: "@scope/tool@2.1.0"}] = spec.packages
  end

  test "rejects unsafe npm package forms", %{workspace: workspace} do
    unsafe_specs = [
      "left-pad",
      "left-pad@^1.3.0",
      "https://registry.npmjs.org/left-pad/-/left-pad-1.3.0.tgz",
      "git+https://github.com/org/repo.git",
      "file:../local",
      "../local",
      "--global",
      "left-pad@1.3.0;rm"
    ]

    for package <- unsafe_specs do
      assert {:error, spec} =
               InstallSpec.normalize(%{
                 manager: "npm",
                 package: package,
                 project_root: workspace
               })

      assert spec.policy_decision == :denied
    end
  end

  test "denies target roots outside configured package roots", %{root: root, workspace: workspace} do
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)

    assert {:error, spec} =
             InstallSpec.normalize(%{
               manager: "npm",
               package: "left-pad@1.3.0",
               project_root: outside
             })

    assert spec.denial_reason == {:target_root_outside_allowed_roots, outside}
    refute spec.resolved_target_root == workspace
  end

  test "normalizes pip as preview-only", %{workspace: workspace} do
    assert {:ok, spec} =
             InstallSpec.normalize(%{
               manager: "pip",
               package: "requests==2.31.0",
               project_root: workspace
             })

    refute spec.execution_available?

    assert spec.dry_run_args == [
             "install",
             "--dry-run",
             "--ignore-installed",
             "--quiet",
             "--report",
             "-",
             "requests==2.31.0"
           ]

    assert hd(spec.warnings) =~ "preview only in v0.10"
  end

  defp put_package_policy!(workspace) do
    settings = %{
      "permissions" => %{"package_install" => "allowed"},
      "package_installs" => %{
        "enabled" => true,
        "allowed_roots" => [workspace],
        "allowed_managers" => ["npm", "pip"]
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
