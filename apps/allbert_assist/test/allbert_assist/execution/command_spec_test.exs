defmodule AllbertAssist.Execution.CommandSpecTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Execution.CommandSpec
  alias AllbertAssist.Execution.Policy
  alias AllbertAssist.Settings

  setup do
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-execution-command-spec-#{System.unique_integer([:positive])}"
      )

    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "fixture\n")

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root, workspace: workspace}
  end

  test "Settings Central exposes execution policy defaults" do
    assert {:ok, false} = Settings.get("execution.local.enabled")
    assert {:ok, commands} = Settings.get("execution.local.allowed_commands")
    assert "ls" in commands
    assert "rg" in commands
    assert {:ok, profiles} = Settings.get("execution.local.command_profiles")
    assert profiles == %{}
  end

  test "settings validates execution policy and command profiles", %{workspace: workspace} do
    assert {:ok, _setting} =
             Settings.put("execution.local.allowed_roots", [workspace], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put(
               "execution.local.command_profiles",
               %{
                 "mix_test" => %{
                   "command" => "mix",
                   "args_prefix" => ["test"],
                   "command_class" => "developer",
                   "timeout_ms" => 30_000,
                   "max_output_bytes" => 65_536
                 }
               },
               %{audit?: false}
             )

    assert {:error, {:invalid_setting, "execution.local.command_profiles", _reason}} =
             Settings.put(
               "execution.local.command_profiles",
               %{"bad profile!" => %{"command" => "mix"}},
               %{audit?: false}
             )

    assert {:error, {:invalid_setting, "execution.local.command_profiles", _reason}} =
             Settings.put(
               "execution.local.command_profiles",
               %{"mix_test" => %{"command" => "mix", "command_class" => "network"}},
               %{audit?: false}
             )
  end

  test "normalizes allowed read-only commands with in-root path operands", %{
    workspace: workspace
  } do
    put_execution_policy!(workspace)

    assert {:ok, spec} =
             CommandSpec.normalize(%{
               executable: "cat",
               args: ["README.md"],
               cwd: workspace
             })

    assert spec.policy_decision == :allowed
    assert spec.command_class == :read_only
    assert spec.resolved_cwd == Path.expand(workspace)
    assert [%{original: "README.md", allowed?: true}] = spec.path_operands
    assert "PATH" in spec.env_summary
  end

  test "denies local execution until enabled", %{workspace: workspace} do
    assert {:error, spec} =
             CommandSpec.normalize(%{
               executable: "ls",
               args: ["-la"],
               cwd: workspace
             })

    assert spec.denial_reason == :local_execution_disabled
  end

  test "denies cwd and path operands outside allowed roots", %{workspace: workspace} do
    put_execution_policy!(workspace)

    assert {:error, cwd_denied} =
             CommandSpec.normalize(%{
               executable: "pwd",
               args: [],
               cwd: System.tmp_dir!()
             })

    assert {:cwd_outside_allowed_roots, _path} = cwd_denied.denial_reason

    assert {:error, path_denied} =
             CommandSpec.normalize(%{
               executable: "ls",
               args: ["-la", "/etc"],
               cwd: workspace
             })

    assert {:path_operands_outside_allowed_roots, denied} = path_denied.denial_reason
    assert [%{original: "/etc", allowed?: false}] = denied
  end

  test "denies env vars outside the allowlist and strips unrequested env", %{workspace: workspace} do
    put_execution_policy!(workspace)

    assert {:error, denied} =
             CommandSpec.normalize(%{
               executable: "pwd",
               args: [],
               cwd: workspace,
               env: %{"PATH" => "/bin", "SECRET_TOKEN" => "nope"}
             })

    assert denied.denial_reason == {:env_not_allowed, ["SECRET_TOKEN"]}

    assert {:ok, allowed} =
             CommandSpec.normalize(%{
               executable: "pwd",
               args: [],
               cwd: workspace,
               env: %{"PATH" => "/bin"}
             })

    assert allowed.env["PATH"] == "/bin"
    refute Map.has_key?(allowed.env, "SECRET_TOKEN")
  end

  test "denies shell syntax, network commands, and inline interpreter eval", %{
    workspace: workspace
  } do
    put_execution_policy!(workspace)

    assert {:error, shell_denied} =
             CommandSpec.normalize(%{
               executable: "ls",
               args: ["-la", "&&", "pwd"],
               cwd: workspace
             })

    assert shell_denied.denial_reason == :shell_syntax_not_allowed

    assert {:error, network_denied} =
             CommandSpec.normalize(%{
               executable: "curl",
               args: ["https://example.com"],
               cwd: workspace
             })

    assert network_denied.command_class == :network
    assert network_denied.denial_reason == :network_command_not_allowed

    assert {:error, eval_denied} =
             CommandSpec.normalize(%{
               executable: "python3",
               args: ["-c", "print('hello')"],
               cwd: workspace
             })

    assert eval_denied.command_class == :interpreter

    assert eval_denied.denial_reason in [
             :blocked_arg_pattern,
             :inline_interpreter_eval_not_allowed
           ]
  end

  test "operator command profiles allow non-default local developer commands", %{
    workspace: workspace
  } do
    put_execution_policy!(workspace, %{
      "mix_test" => %{
        "command" => "mix",
        "args_prefix" => ["test"],
        "command_class" => "developer",
        "timeout_ms" => 20_000,
        "max_output_bytes" => 32_000
      }
    })

    assert {:ok, spec} =
             CommandSpec.normalize(%{
               executable: "mix",
               args: ["test"],
               cwd: workspace
             })

    assert spec.command_class == :developer
    assert spec.command_profile == "mix_test"
    assert spec.timeout_ms == 20_000

    assert {:error, denied} =
             CommandSpec.normalize(%{
               executable: "mix",
               args: ["deps.get"],
               cwd: workspace
             })

    assert denied.denial_reason == {:command_not_allowed, "mix"}
  end

  test "policy helper expands allowed roots and filters env", %{workspace: workspace} do
    put_execution_policy!(workspace)

    assert {:ok, policy} = Policy.load()
    assert Policy.root_allowed?(policy, workspace)
    assert Policy.root_allowed?(policy, Path.join(workspace, "README.md"))
    refute Policy.root_allowed?(policy, System.tmp_dir!())
    assert Map.has_key?(Policy.env_for(policy, %{"PATH" => "/bin", "TOKEN" => "no"}), "PATH")
    refute Map.has_key?(Policy.env_for(policy, %{"PATH" => "/bin", "TOKEN" => "no"}), "TOKEN")
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
