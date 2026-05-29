defmodule AllbertAssist.Actions.SkillActionsTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  setup do
    original_paths_config = Application.get_env(:allbert_assist, Paths)
    original_settings_config = Application.get_env(:allbert_assist, Settings)

    root =
      Path.join(System.tmp_dir!(), "allbert-skill-actions-#{System.unique_integer([:positive])}")

    home = Path.join(root, "home")

    Application.put_env(:allbert_assist, Paths,
      home: home,
      skills_root: Path.join(home, "skills")
    )

    Application.put_env(:allbert_assist, Settings, root: Path.join(root, "settings"))

    on_exit(fn ->
      restore_env(Paths, original_paths_config)
      restore_env(Settings, original_settings_config)
      File.rm_rf!(root)
    end)

    {:ok, root: root, home: home}
  end

  test "validate_skill reports structural contract validity without trust escalation" do
    assert {:ok, response} =
             Runner.run("validate_skill", %{path: fixture("allbert-capability")}, context())

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed
    assert response.validation.status == :valid
    assert response.validation.name == "allbert-capability"
    assert response.validation.contract.validation_status == :valid
    refute response.validation.contract.execution_eligible?
    assert [%{name: "validate_skill", validation: validation}] = response.actions
    assert validation.path =~ "allbert-capability"
  end

  test "validate_skill keeps malformed skills inspectable as diagnostics" do
    assert {:ok, response} =
             Runner.run("validate_skill", %{path: fixture("invalid-yaml")}, context())

    assert response.status == :completed
    assert response.validation.status == :invalid
    assert Enum.any?(response.validation.diagnostics, &(&1.code == :invalid_yaml))
  end

  test "create_skill writes only a standard SKILL.md wrapper for a skill-backed action", %{
    root: root
  } do
    skill_root = Path.join(root, "created-skills")

    assert {:ok, response} =
             Runner.run(
               "create_skill",
               %{
                 name: "Append Helper",
                 action: "append_memory",
                 permission: "memory_write",
                 description: "Save a short memory helper.",
                 root: skill_root
               },
               context()
             )

    assert response.status == :completed
    assert response.permission_decision.decision == :allowed
    assert response.skill.validation.status == :valid
    assert response.skill.validation.name == "append-helper"
    assert response.skill.validation.contract.validation_status == :valid
    refute response.skill.validation.contract.execution_eligible?
    assert File.exists?(Path.join([skill_root, "append-helper", "SKILL.md"]))
    refute File.dir?(Path.join([skill_root, "append-helper", "scripts"]))
    assert [] == Path.wildcard(Path.join([skill_root, "append-helper", "**", "*.ex"]))

    skill_markdown = File.read!(Path.join([skill_root, "append-helper", "SKILL.md"]))
    assert skill_markdown =~ "allbert.actions: append_memory"
    assert skill_markdown =~ "allbert.permissions: memory_write"
    refute skill_markdown =~ "Module.create"
  end

  test "create_skill rejects unknown actions before writing", %{root: root} do
    skill_root = Path.join(root, "created-skills")

    assert {:ok, response} =
             Runner.run(
               "create_skill",
               %{
                 name: "Bad Helper",
                 action: "missing_action",
                 permission: "memory_write",
                 root: skill_root
               },
               context()
             )

    assert response.status == :error
    assert {:invalid_contract, validation} = response.error
    assert Enum.any?(validation.diagnostics, &(&1.code == :unknown_action))
    refute File.exists?(Path.join([skill_root, "bad-helper", "SKILL.md"]))
  end

  defp fixture(name), do: Path.join(@fixtures, name)

  defp context do
    %{request: %{operator_id: "local", channel: :test, input_signal_id: "sig-skill-helper"}}
  end

  defp restore_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_env(module, config), do: Application.put_env(:allbert_assist, module, config)
end
