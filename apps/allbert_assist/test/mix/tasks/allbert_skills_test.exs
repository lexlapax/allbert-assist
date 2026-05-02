defmodule Mix.Tasks.Allbert.SkillsTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Paths
  alias AllbertAssist.Settings
  alias Mix.Tasks.Allbert.Skills, as: SkillsTask

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-skills-task-#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")

    Application.put_env(:allbert_assist, Paths,
      home: home,
      skills_root: Path.join(home, "skills")
    )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
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

  defp fixture(name), do: Path.join(@fixtures, name)

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
