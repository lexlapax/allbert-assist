defmodule Mix.Tasks.Allbert.SkillsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Confirmations
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Skills, as: SkillsTask

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  setup do
    original_confirmations_config = Application.get_env(:allbert_assist, Confirmations)
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-skills-task-#{System.unique_integer([:positive])}")

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
      Mix.Task.reenable("allbert.skills")
      File.rm_rf!(root)
    end)

    {:ok, root: root}
  end

  test "validate prints local skill diagnostics" do
    output =
      capture_io(fn ->
        assert :ok = SkillsTask.run(["validate", fixture("allbert-capability")])
      end)

    assert output =~ "Validation: valid"
    assert output =~ "Name: allbert-capability"
    assert output =~ "Contract: valid"
    assert output =~ "Execution eligible: false"
  end

  test "create writes a local skill through the registered action boundary", %{root: root} do
    skill_root = Path.join(root, "created-skills")

    output =
      capture_io(fn ->
        assert :ok =
                 SkillsTask.run([
                   "create",
                   "demo-memory",
                   "append_memory",
                   "memory_write",
                   "Save",
                   "a",
                   "memory",
                   "helper",
                   "--root",
                   skill_root
                 ])
      end)

    assert output =~ "Created:"
    assert output =~ "Validation: valid"
    assert File.exists?(Path.join([skill_root, "demo-memory", "SKILL.md"]))
  end

  test "create raises for unknown actions" do
    assert_raise Mix.Error, ~r/invalid_contract/, fn ->
      SkillsTask.run(["create", "bad-helper", "missing_action", "read_only"])
    end
  end

  test "run creates pending script confirmation through the action boundary", %{root: root} do
    workspace = Path.join(root, "workspace")
    File.mkdir_p!(workspace)
    write_script_skill!(Path.join(root, "home"), "demo-script")
    put_script_policy!(workspace)

    output =
      capture_io(fn ->
        assert :ok =
                 SkillsTask.run([
                   "run",
                   "demo-script",
                   "scripts/hello",
                   "--cwd",
                   workspace,
                   "--",
                   "arg"
                 ])
      end)

    assert output =~ "Status: needs_confirmation"
    assert output =~ "Skill: demo-script"
    assert output =~ "Script: scripts/hello"
    assert output =~ "Confirmation:"

    [pending] = Confirmations.list(status: :pending)
    assert pending["target_action"]["name"] == "run_skill_script"
    assert pending["params_summary"]["script_path"] == "scripts/hello"
  end

  defp fixture(name), do: Path.join(@fixtures, name)

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
