defmodule AllbertAssist.Skills.BuiltInPackTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Skills
  alias AllbertAssist.Skills.CapabilityContract

  @built_in_names [
    "append-memory",
    "direct-answer",
    "external-network-request",
    "list-skills",
    "plan-shell-command",
    "read-recent-memory",
    "read-skill",
    "unsupported-resource-workflow"
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

  test "built-in skill contracts validate against registered action capabilities" do
    assert {:ok, skills} = Skills.list()

    built_ins = Enum.filter(skills, &(&1.source_scope == :built_in))

    assert Enum.map(built_ins, & &1.name) == @built_in_names

    for skill <- built_ins do
      validation = CapabilityContract.validate(skill.capability_contract, skill: skill)

      assert validation.status == :valid
      assert validation.execution_eligible?
      assert validation.diagnostics == []
      assert Enum.all?(validation.actions, & &1.registered?)
      assert Enum.all?(validation.actions, & &1.skill_backed?)
      assert validation.permissions == [skill.permission]
    end
  end

  test "malicious capability contracts are invalid and non-executable" do
    unknown_action =
      CapabilityContract.from_metadata(%{
        "allbert.actions" => "missing_action",
        "allbert.permissions" => "read_only",
        "allbert.confirmation" => "not_required"
      })

    unknown_permission =
      CapabilityContract.from_metadata(%{
        "allbert.actions" => "append_memory",
        "allbert.permissions" => "root_access",
        "allbert.confirmation" => "not_required"
      })

    unknown_confirmation =
      CapabilityContract.from_metadata(%{
        "allbert.actions" => "append_memory",
        "allbert.permissions" => "memory_write",
        "allbert.confirmation" => "auto_approve_everything"
      })

    internal_action =
      CapabilityContract.from_metadata(%{
        "allbert.actions" => "record_trace",
        "allbert.permissions" => "memory_write",
        "allbert.confirmation" => "not_required"
      })

    multi_action =
      CapabilityContract.from_metadata(%{
        "allbert.actions" => ["append_memory", "read_recent_memory"],
        "allbert.permissions" => ["memory_write", "read_only"],
        "allbert.confirmation" => "not_required"
      })

    validations =
      Enum.map(
        [unknown_action, unknown_permission, unknown_confirmation, internal_action, multi_action],
        &CapabilityContract.validate(&1)
      )

    assert Enum.all?(validations, &(&1.status == :invalid))
    refute Enum.any?(validations, & &1.execution_eligible?)

    diagnostic_codes =
      validations
      |> Enum.flat_map(& &1.diagnostics)
      |> Enum.map(& &1.code)

    assert :unknown_action in diagnostic_codes
    assert :unknown_permission in diagnostic_codes
    assert :unknown_confirmation in diagnostic_codes
    assert :action_not_skill_backed in diagnostic_codes
    assert :multi_action_workflow_not_executable in diagnostic_codes
  end

  test "snake-case aliases read built-in skills" do
    assert {:ok, %{skill: skill}} = Skills.read("plan_shell_command")

    assert skill.name == "plan-shell-command"
    assert "plan_shell_command" in skill.aliases
  end

  test "built-in skills activate through progressive disclosure" do
    assert {:ok, activation} = Skills.activate("append-memory")

    assert activation.name == "append-memory"
    assert activation.source_scope == :built_in
    assert activation.trust_status == :trusted
    assert activation.instructions =~ "## Skill Context"
    assert activation.instructions =~ "## Resource Inventory"
    assert activation.instructions =~ "execute scripts"
    assert activation.capability_contract.actions == ["append_memory"]
    assert activation.resource_inventory == []
  end

  test "built-in pack has no registry diagnostics in isolated test config" do
    assert {:ok, diagnostics} = Skills.diagnostics()

    refute Enum.any?(diagnostics, &(&1.source_scope == :built_in))
  end
end
