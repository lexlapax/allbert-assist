defmodule AllbertAssist.Coding.M7TrustApprovalTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Coding.CommandGrants
  alias AllbertAssist.Paths
  alias AllbertAssist.Resources.Grants
  alias AllbertAssist.Security.PermissionGate
  alias AllbertAssist.Settings
  alias AllbertAssist.Settings.Schema

  @env_vars [
    "ALLBERT_HOME",
    "ALLBERT_HOME_DIR",
    "ALLBERT_SETTINGS_ROOT",
    "ALLBERT_SETTINGS_MASTER_KEY"
  ]

  setup do
    original_env = Map.new(@env_vars, &{&1, System.get_env(&1)})
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    Enum.each(@env_vars, &System.delete_env/1)
    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    home = temp_path("home")
    workspace = Path.join(home, "workspace")

    File.mkdir_p!(workspace)
    File.write!(Path.join(workspace, "README.md"), "fixture\n")
    File.mkdir_p!(Path.join(workspace, ".git"))

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    put_execution_policy!(workspace)

    {:ok, home: home, workspace: workspace}
  end

  test "M7 Settings Central keys are safe writable and validate" do
    for {key, value} <- [
          {"coding.pi_mode.enabled", false},
          {"coding.trusted_operator_id", nil},
          {"coding.default_approval_mode", "default"},
          {"coding.command_grants.default_ttl_ms", 86_400_000},
          {"coding.command_grants.max_entries_per_repo", 100}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end
  end

  test "local-coding tier requires enabled Pi-mode, trusted operator, TUI, and main session",
       %{workspace: workspace} do
    context = trusted_context(workspace)

    assert PermissionGate.coding_tier(context) == :none

    put_pi_mode_settings!()

    assert PermissionGate.coding_tier(context) == :local_coding_operator
    assert PermissionGate.coding_tier(%{context | channel: %{name: :telegram}}) == :none
    assert PermissionGate.coding_tier(%{context | session: %{main?: false}}) == :none
    assert PermissionGate.coding_tier(Map.put(context, :channel_originated?, true)) == :none
    assert PermissionGate.coding_tier(Map.put(context, :scheduled?, true)) == :none
    assert PermissionGate.coding_tier(Map.put(context, :generated_code_session?, true)) == :none
  end

  test "approval modes suppress only the local prompt cost and preserve decisions",
       %{workspace: workspace} do
    put_pi_mode_settings!()

    default_write = PermissionGate.authorize(:coding_file_write, trusted_context(workspace))
    assert default_write.decision == :needs_confirmation
    assert default_write.requires_confirmation

    accept_context = approval_context(workspace, "accept-edits")
    accept_write = PermissionGate.authorize(:coding_file_write, accept_context)
    accept_shell = PermissionGate.authorize(:coding_shell_execute, accept_context)

    assert accept_write.decision == :needs_confirmation
    refute accept_write.requires_confirmation
    assert accept_write.trace.confirmation_cost == :suppressed
    assert accept_write.trace.approval_mode == :accept_edits
    assert accept_write.trace.coding_tier == :local_coding_operator
    assert accept_write.policy.effective == :needs_confirmation

    assert accept_shell.decision == :needs_confirmation
    assert accept_shell.requires_confirmation

    tier_context = approval_context(workspace, "tier")
    tier_shell = PermissionGate.authorize(:coding_shell_execute, tier_context)

    assert tier_shell.decision == :needs_confirmation
    refute tier_shell.requires_confirmation
    assert tier_shell.policy.effective == :needs_confirmation

    plan_context = approval_context(workspace, "plan")
    assert PermissionGate.authorize(:coding_file_read, plan_context).decision == :allowed
    assert PermissionGate.authorize(:coding_file_write, plan_context).decision == :denied
    assert PermissionGate.authorize(:coding_shell_execute, plan_context).decision == :denied
  end

  test "accept-edits runs file writes without creating a confirmation", %{workspace: workspace} do
    put_pi_mode_settings!()

    assert {:ok, response} =
             Runner.run(
               "write",
               %{path: "accepted.txt", content: "accepted\n"},
               approval_context(workspace, "accept-edits")
             )

    assert response.status == :completed
    assert response.permission_decision.decision == :needs_confirmation
    refute response.permission_decision.requires_confirmation
    refute Map.has_key?(response, :confirmation_id)
    assert File.read!(Path.join(workspace, "accepted.txt")) == "accepted\n"
  end

  test "remembered command grants match exact repo cwd permission and command",
       %{workspace: workspace} do
    put_pi_mode_settings!()

    params = %{mode: :argv, executable: "printf", args: ["hello"], cwd: workspace}
    other_args = %{params | args: ["goodbye"]}
    context = trusted_context(workspace)

    assert {:ok, grant} =
             CommandGrants.remember(params,
               context: context,
               permission: :coding_shell_execute,
               audit?: false
             )

    assert get_in(grant, ["scope", "kind"]) == "canonical_command"
    assert get_in(grant, ["metadata", "grant_kind"]) == "coding_command"
    refute inspect(grant) =~ "hello"

    assert {:ok, _grant} =
             CommandGrants.find_applicable(params,
               context: context,
               permission: :coding_shell_execute
             )

    assert {:error, :no_matching_command_grant} =
             CommandGrants.find_applicable(other_args,
               context: context,
               permission: :coding_shell_execute
             )

    command_context = put_in(context, [:coding, :command_params], params)
    decision = PermissionGate.authorize(:coding_shell_execute, command_context)

    assert decision.decision == :needs_confirmation
    refute decision.requires_confirmation

    assert {:ok, response} =
             Runner.run(
               "bash",
               %{executable: "printf", args: ["hello"], cwd: "."},
               context
             )

    assert response.status == :completed
    assert response.permission_decision.decision == :needs_confirmation
    refute response.permission_decision.requires_confirmation
    refute Map.has_key?(response, :confirmation_id)

    assert {:ok, _revoked} = Grants.revoke(grant["id"], %{audit?: false})

    assert {:error, :no_matching_command_grant} =
             CommandGrants.find_applicable(params,
               context: context,
               permission: :coding_shell_execute
             )
  end

  test "command grants expire and enforce a per-repo active-entry cap", %{workspace: workspace} do
    put_pi_mode_settings!()
    context = trusted_context(workspace)
    now = DateTime.utc_now()
    params = %{mode: :argv, executable: "printf", args: ["hello"], cwd: workspace}

    assert {:ok, expired} =
             CommandGrants.remember(params,
               context: context,
               permission: :coding_shell_execute,
               expires_at: DateTime.add(now, -1, :second),
               audit?: false
             )

    assert {:error, :no_matching_command_grant} =
             CommandGrants.find_applicable(params,
               context: context,
               permission: :coding_shell_execute,
               now: now
             )

    assert {:ok, _revoked_expired} = Grants.revoke(expired["id"], %{audit?: false})

    assert {:ok, _setting} =
             Settings.put("coding.command_grants.max_entries_per_repo", 1, %{audit?: false})

    assert {:ok, _grant} =
             CommandGrants.remember(params,
               context: context,
               permission: :coding_shell_execute,
               audit?: false
             )

    second = %{params | args: ["second"]}

    assert {:error, {:max_command_grants_per_repo, _fingerprint, 1}} =
             CommandGrants.remember(second,
               context: context,
               permission: :coding_shell_execute,
               audit?: false
             )
  end

  defp trusted_context(workspace) do
    %{
      actor: %{id: "local"},
      operator_id: "local",
      user_id: "local",
      channel: %{name: :tui, trust: :local},
      surface: :tui,
      cwd_jail: workspace,
      coding: %{cwd_jail: workspace},
      session: %{main?: true}
    }
  end

  defp approval_context(workspace, approval_mode) do
    put_in(trusted_context(workspace), [:coding, :approval_mode], approval_mode)
  end

  defp put_pi_mode_settings! do
    assert {:ok, _setting} = Settings.put("coding.pi_mode.enabled", true, %{audit?: false})
    assert {:ok, _setting} = Settings.put("coding.trusted_operator_id", "local", %{audit?: false})
  end

  defp put_execution_policy!(workspace) do
    settings = %{
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [workspace],
          "allowed_commands" => ["pwd", "printf"],
          "env_allowlist" => [],
          "max_timeout_ms" => 1_000,
          "max_output_bytes" => 2_000
        }
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp temp_path(prefix) do
    Path.join(
      System.tmp_dir!(),
      "allbert-m7-#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(_key, nil), do: :ok
  defp restore_app_env(key, value), do: Application.put_env(:allbert_assist, key, value)
end
