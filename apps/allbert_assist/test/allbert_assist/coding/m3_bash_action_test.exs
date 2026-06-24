defmodule AllbertAssist.Coding.M3BashActionTest do
  use ExUnit.Case, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
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
    outside = Path.join(home, "outside")

    File.mkdir_p!(workspace)
    File.mkdir_p!(outside)
    File.write!(Path.join(workspace, "README.md"), "fixture\n")

    System.put_env("ALLBERT_HOME", home)

    on_exit(fn ->
      File.rm_rf!(home)
      restore_env(original_env)
      restore_app_env(Paths, original_paths_config)
      restore_app_env(Settings, original_settings_config)
    end)

    put_execution_policy!(workspace)

    {:ok, home: home, workspace: workspace, outside: outside}
  end

  test "M3 Settings Central keys are safe writable and validate" do
    for {key, value} <- [
          {"coding.bash.timeout_ms", 120_000},
          {"coding.bash.max_output_bytes", 120_000},
          {"coding.bash.allow_raw_shell", false},
          {"permissions.coding_shell_execute", "needs_confirmation"}
        ] do
      assert key in Schema.safe_write_keys()
      assert %{writable?: true, sensitive?: false} = Schema.schema()[key]
      assert :ok = Schema.validate_key_value(key, value)
    end
  end

  test "bash creates a confirmation and approval resumes argv command", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run("bash", %{executable: "pwd", args: [], cwd: "."}, context(workspace))

    assert response.status == :needs_confirmation
    assert response.permission_decision.decision == :needs_confirmation
    assert response.confirmation_id
    assert response.model_payload =~ "mode=argv"
    assert get_in(response.confirmation, ["resume_params_ref", "args"]) == "[REDACTED_ARGS]"

    assert {:ok, approval} =
             Runner.run(
               "approve_confirmation",
               %{id: response.confirmation_id},
               context(workspace)
             )

    assert approval.status == :completed
    assert approval.confirmation["status"] == "approved"

    metadata = approval.actions |> hd() |> Map.fetch!(:confirmation_metadata)
    assert metadata.target_resumed?
    assert metadata.target_status == :completed
    assert get_in(metadata.target_result, [:output_data, :stdout_preview]) =~ workspace
  end

  test "bash treats plain command strings as argv commands", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run("bash", %{"command" => "pwd", "cwd" => "."}, context(workspace))

    assert response.status == :needs_confirmation
    assert response.permission_decision.decision == :needs_confirmation
    assert response.model_payload =~ "mode=argv"
    assert response.model_payload =~ "executable=\"pwd\""
    assert get_in(response.confirmation, ["resume_params_ref", "args"]) == "[REDACTED_ARGS]"

    assert {:ok, quoted} =
             Runner.run(
               "bash",
               %{"command" => "printf 'hello world\\n'", "cwd" => "."},
               context(workspace)
             )

    assert quoted.status == :needs_confirmation
    assert quoted.model_payload =~ "mode=argv"
    assert quoted.model_payload =~ "executable=\"printf\""
  end

  test "bash enforces cwd jail before command execution", %{workspace: workspace} do
    assert {:ok, response} =
             Runner.run(
               "bash",
               %{executable: "pwd", args: [], cwd: "../outside"},
               context(workspace)
             )

    assert response.status == :denied
    assert response.actions |> hd() |> Map.fetch!(:denial_reason) == :path_outside_cwd_jail
  end

  test "bash output cap and env allowlist flow through local runner", %{workspace: workspace} do
    assert {:ok, _setting} =
             Settings.put("coding.bash.max_output_bytes", 1_024, %{audit?: false})

    output = String.duplicate("a", 1_500)

    assert {:ok, response} =
             Runner.run(
               "bash",
               %{
                 executable: "printf",
                 args: [output],
                 cwd: ".",
                 env: %{"VISIBLE" => "ok"}
               },
               approved_context(workspace)
             )

    assert response.status == :completed
    assert response.output_data.truncated?
    assert byte_size(response.output_data.stdout_preview) == 1_024
    assert response.output_data.stdout_preview == String.duplicate("a", 1_024)
    assert response.output_data.command.env_keys == ["VISIBLE"]
    assert response.output_data.command.args == ["[REDACTED_ARGS]"]
    refute inspect(response.output_data.command) =~ output
    refute inspect(response.output_data) =~ "HIDDEN"
    refute inspect(response.output_data) =~ "nope"

    assert {:ok, denied_env} =
             Runner.run(
               "bash",
               %{executable: "pwd", args: [], cwd: ".", env: %{"HIDDEN" => "nope"}},
               approved_context(workspace)
             )

    assert denied_env.status == :denied

    assert denied_env.actions |> hd() |> Map.fetch!(:denial_reason) ==
             {:env_not_allowed, ["HIDDEN"]}
  end

  test "bash raw shell is disabled unless the local-coding tier and setting allow it", %{
    workspace: workspace
  } do
    assert {:ok, disabled} =
             Runner.run("bash", %{command: "printf hello | cat", cwd: "."}, context(workspace))

    assert disabled.status == :denied
    assert disabled.actions |> hd() |> Map.fetch!(:denial_reason) == :raw_shell_disabled

    assert {:ok, _setting} = Settings.put("coding.bash.allow_raw_shell", true, %{audit?: false})

    non_tier_context = put_in(context(workspace), [:coding, :trusted_operator_id], "other")

    assert {:ok, non_tier} =
             Runner.run("bash", %{command: "printf hello | cat", cwd: "."}, non_tier_context)

    assert non_tier.status == :denied

    assert non_tier.actions |> hd() |> Map.fetch!(:denial_reason) ==
             :local_coding_operator_required

    assert {:ok, raw_pending} =
             Runner.run(
               "bash",
               %{command: "printf hello | cat", cwd: "."},
               tier_context(workspace)
             )

    assert raw_pending.status == :needs_confirmation
    assert raw_pending.model_payload =~ "mode=raw_shell"

    assert get_in(raw_pending.confirmation, ["resume_params_ref", "command"]) ==
             "[REDACTED_COMMAND]"

    refute inspect(raw_pending.actions) =~ "printf hello"
  end

  test "bash refuses opaque sub-agent spawn attempts even at the raw-shell tier", %{
    workspace: workspace
  } do
    assert {:ok, _setting} = Settings.put("coding.bash.allow_raw_shell", true, %{audit?: false})

    assert {:ok, response} =
             Runner.run(
               "bash",
               %{command: "codex exec do-work", cwd: "."},
               tier_context(workspace)
             )

    assert response.status == :denied

    assert response.actions |> hd() |> Map.fetch!(:denial_reason) ==
             :bash_spawned_subagent_not_allowed

    assert {:ok, argv_response} =
             Runner.run(
               "bash",
               %{command: "codex exec do-work", cwd: "."},
               tier_context(workspace)
             )

    assert argv_response.status == :denied

    assert argv_response.actions |> hd() |> Map.fetch!(:denial_reason) ==
             :bash_spawned_subagent_not_allowed
  end

  test "bash raw shell enforces env allowlist and requested limits at the tier", %{
    workspace: workspace
  } do
    assert {:ok, _setting} = Settings.put("coding.bash.allow_raw_shell", true, %{audit?: false})

    assert {:ok, denied_env} =
             Runner.run(
               "bash",
               %{command: "printf hello | cat", cwd: ".", env: %{"HIDDEN" => "nope"}},
               tier_context(workspace)
             )

    assert denied_env.status == :denied

    assert denied_env.actions |> hd() |> Map.fetch!(:denial_reason) ==
             {:env_not_allowed, ["HIDDEN"]}

    assert {:ok, denied_timeout} =
             Runner.run(
               "bash",
               %{command: "printf hello | cat", cwd: ".", timeout_ms: 2_000},
               tier_context(workspace)
             )

    assert denied_timeout.status == :denied

    assert denied_timeout.actions |> hd() |> Map.fetch!(:denial_reason) ==
             {:timeout_exceeds_policy, 2_000, 1_000}
  end

  defp context(workspace) do
    %{
      actor: "local",
      operator_id: "local",
      user_id: "local",
      channel: %{name: :tui, trust: :local},
      surface: :tui,
      cwd_jail: workspace,
      coding: %{cwd_jail: workspace, pi_mode_enabled: true, trusted_operator_id: "local"},
      session: %{main?: true}
    }
  end

  defp approved_context(workspace) do
    Map.put(context(workspace), :confirmation, %{approved?: true})
  end

  defp tier_context(workspace) do
    context(workspace)
  end

  defp put_execution_policy!(workspace) do
    settings = %{
      "execution" => %{
        "local" => %{
          "enabled" => true,
          "allowed_roots" => [workspace],
          "allowed_commands" => ["pwd", "printf", "sleep"],
          "env_allowlist" => ["VISIBLE"],
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
      "allbert-v057-m3-#{prefix}-#{System.unique_integer([:positive])}"
    )
  end

  defp restore_env(original_env) do
    Enum.each(original_env, fn
      {key, nil} -> System.delete_env(key)
      {key, value} -> System.put_env(key, value)
    end)
  end

  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
