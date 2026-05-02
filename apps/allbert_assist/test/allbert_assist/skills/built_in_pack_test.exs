defmodule AllbertAssist.Skills.BuiltInPackTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Skills

  @built_in_names [
    "append-memory",
    "direct-answer",
    "external-network-request",
    "list-skills",
    "plan-shell-command",
    "read-recent-memory",
    "read-skill"
  ]

  test "built-in skill pack is loaded from priv skills" do
    assert {:ok, skills} = Skills.list()

    built_ins = Enum.filter(skills, &(&1.source_scope == :built_in))

    assert Enum.map(built_ins, & &1.name) == @built_in_names
    refute Enum.any?(skills, &(&1.source_scope == :built_in_legacy))
    assert Enum.all?(built_ins, &(&1.kind == :native_action))
  end

  test "built-in skill metadata remains descriptive and inert" do
    assert {:ok, %{skill: skill, body: body}} = Skills.read("append-memory")

    assert skill.source_scope == :built_in
    assert skill.capability_contract.status == :draft
    assert skill.capability_contract.actions == ["append_memory"]
    assert skill.capability_contract.permissions == ["memory_write"]
    assert body =~ "Use the `append_memory` Allbert action"
    assert skill.spec.resources == []
  end

  test "snake-case aliases read built-in skills" do
    assert {:ok, %{skill: skill}} = Skills.read("plan_shell_command")

    assert skill.name == "plan-shell-command"
    assert "plan_shell_command" in skill.aliases
  end

  test "built-in pack has no registry diagnostics in isolated test config" do
    assert {:ok, diagnostics} = Skills.diagnostics()

    refute Enum.any?(diagnostics, &(&1.source_scope == :built_in))
  end
end
