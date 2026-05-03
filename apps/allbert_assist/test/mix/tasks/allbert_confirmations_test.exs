defmodule Mix.Tasks.Allbert.ConfirmationsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Confirmations, as: ConfirmationsTask

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(
        System.tmp_dir!(),
        "allbert-confirmations-task-#{System.unique_integer([:positive])}"
      )

    home = Path.join(root, "home")

    Application.put_env(:allbert_assist, Paths,
      home: home,
      skills_root: Path.join(home, "skills")
    )

    Application.put_env(:allbert_assist, Confirmations, root: Path.join(home, "confirmations"))
    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Confirmations, original_confirmations_config)
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      Mix.Task.reenable("allbert.confirmations")
      File.rm_rf!(root)
    end)

    {:ok, root: root, home: home}
  end

  test "lists, shows, denies, and lists resolved confirmations" do
    assert {:ok, record} = Confirmations.create(base_attrs())

    list_output = capture_io(fn -> assert :ok = ConfirmationsTask.run(["list"]) end)
    assert list_output =~ record["id"]
    assert list_output =~ "status=pending"
    assert list_output =~ "origin=local/cli"

    show_output = capture_io(fn -> assert :ok = ConfirmationsTask.run(["show", record["id"]]) end)
    assert show_output =~ "Requested:"
    assert show_output =~ "Resolver: none/none"

    deny_output =
      capture_io(fn ->
        assert :ok =
                 ConfirmationsTask.run(["deny", record["id"], "--reason", "not", "needed"])
      end)

    assert deny_output =~ "status=denied"
    assert deny_output =~ "Resolver: local/cli"

    resolved_output =
      capture_io(fn -> assert :ok = ConfirmationsTask.run(["list", "--resolved"]) end)

    assert resolved_output =~ record["id"]
    assert resolved_output =~ "status=denied"
  end

  test "approve and expire commands render operator output" do
    assert {:ok, approval} = Confirmations.create(Map.put(base_attrs(), :id, "conf_cli_approve"))

    approve_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["approve", approval["id"], "--reason", "ok"])
      end)

    assert approve_output =~ "conf_cli_approve status=adapter_unavailable"
    assert approve_output =~ "Approved, but not executed"
    assert approve_output =~ "New v0.10 external-network requests use the confirmed Req adapter."

    show_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["show", approval["id"]])
      end)

    assert show_output =~ "status=adapter_unavailable"
    assert show_output =~ "Approved, but not executed"

    resolved_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["list", "--resolved"])
      end)

    assert resolved_output =~ "conf_cli_approve status=adapter_unavailable"
    assert resolved_output =~ "Approved, but not executed"

    expire_output = capture_io(fn -> assert :ok = ConfirmationsTask.run(["expire"]) end)
    assert expire_output =~ "Expired: 0"
  end

  test "missing confirmation raises a Mix error" do
    assert_raise Mix.Error, ~r/confirmation_not_found/, fn ->
      ConfirmationsTask.run(["show", "missing"])
    end
  end

  test "shows and approves skill script confirmation metadata", %{root: root, home: home} do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    write_script_skill!(home, "demo-script")
    put_script_policy!(workspace)

    assert {:ok, pending_response} =
             Runner.run(
               "run_skill_script",
               %{
                 skill_name: "demo-script",
                 script_path: "scripts/hello",
                 args: [],
                 cwd: workspace
               },
               %{actor: "local", channel: :cli, surface: "mix allbert.skills"}
             )

    show_output =
      capture_io(fn ->
        assert :ok = ConfirmationsTask.run(["show", pending_response.confirmation_id])
      end)

    assert show_output =~ "target=run_skill_script"
    assert show_output =~ "Skill: demo-script"
    assert show_output =~ "Script: scripts/hello"

    approve_output =
      capture_io(fn ->
        assert :ok =
                 ConfirmationsTask.run([
                   "approve",
                   pending_response.confirmation_id,
                   "--reason",
                   "ok"
                 ])
      end)

    assert approve_output =~ "status=approved"
    assert approve_output =~ "Result: completed"
    assert approve_output =~ "Output preview: hello from demo-script"
  end

  defp base_attrs do
    %{
      origin: %{actor: "local", channel: :cli, surface: "mix allbert.ask"},
      target_action: %{name: "external_network_request"},
      target_permission: :external_network,
      target_execution_mode: :external_network_unavailable,
      security_decision: %{permission: :external_network, decision: :needs_confirmation},
      params_summary: %{url: "https://example.com"}
    }
  end

  defp write_script_skill!(home, name) do
    skill_root = Path.join([home, "skills", name])
    script_path = Path.join([skill_root, "scripts", "hello"])

    File.mkdir_p!(Path.dirname(script_path))
    File.write!(Path.join(skill_root, "SKILL.md"), skill_markdown(name))
    File.write!(script_path, "#!/bin/sh\nprintf 'hello from #{name}\\n'\n")
    File.chmod!(script_path, 0o755)
  end

  defp skill_markdown(name) do
    """
    ---
    name: #{name}
    description: #{name} test script skill.
    metadata:
      allbert.kind: capability
      allbert.actions: run_skill_script
      allbert.permissions: skill_script_execute
      allbert.confirmation: required
    ---

    Run only through Allbert.
    """
  end

  defp put_script_policy!(workspace) do
    settings = %{
      "permissions" => %{"skill_script_execute" => "allowed"},
      "execution" => %{
        "local" => %{"allowed_roots" => [workspace]},
        "skill_scripts" => %{"enabled" => true}
      }
    }

    assert {:ok, _settings} = Settings.write_user_settings(settings)
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
