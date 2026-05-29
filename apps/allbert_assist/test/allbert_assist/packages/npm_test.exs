defmodule AllbertAssist.Packages.NpmTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Packages.ManagerProfile
  alias AllbertAssist.Packages.Npm

  test "builds npm dry-run and install argv without shell strings" do
    spec = %{
      manager: :npm,
      packages: [%{spec: "left-pad@1.3.0"}],
      save_mode: :optional,
      profile: %ManagerProfile{
        executable: "npm",
        args_prefix: [],
        plan_args: [],
        install_args: [],
        lifecycle_scripts_allowed?: false,
        git_dependencies_allowed?: false
      }
    }

    assert Npm.dry_run_args(spec) == [
             "install",
             "left-pad@1.3.0",
             "--save-optional",
             "--json",
             "--save-exact",
             "--no-fund",
             "--no-audit",
             "--ignore-scripts",
             "--allow-git=none",
             "--dry-run"
           ]

    assert Npm.install_args(spec) == [
             "install",
             "left-pad@1.3.0",
             "--save-optional",
             "--json",
             "--save-exact",
             "--no-fund",
             "--no-audit",
             "--ignore-scripts",
             "--allow-git=none"
           ]
  end
end
