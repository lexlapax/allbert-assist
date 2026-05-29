defmodule AllbertAssist.Skills.ParserTest do
  use ExUnit.Case, async: true
  @moduletag :global_process_serial

  alias AllbertAssist.Skills.AgentSkillSpec
  alias AllbertAssist.Skills.Parser
  alias AllbertAssist.Skills.Resource

  @fixtures Path.expand("../../support/fixtures/skills", __DIR__)

  test "parses a valid standard Agent Skill without Allbert metadata" do
    assert {:ok, %AgentSkillSpec{} = spec} = Parser.parse_dir(fixture("standard-skill"))

    assert spec.name == "standard-skill"

    assert spec.description ==
             "Explain a small local workflow without any Allbert-specific metadata."

    assert spec.license == "MIT"
    assert spec.compatibility == "Agent Skills compatible."
    assert spec.metadata == %{}
    assert spec.allowed_tools == []
    assert spec.external_fields == %{}
    assert spec.body =~ "## Workflow"
    assert spec.resources == []
    assert spec.diagnostics == []
  end

  test "parses Allbert metadata as inert namespaced context" do
    assert {:ok, spec} = Parser.parse_dir(fixture("allbert-capability"))

    assert spec.allowed_tools == ["allbert:action:append_memory"]
    assert spec.metadata["allbert.kind"] == "capability"
    assert spec.metadata["allbert.actions"] == "append_memory"
    assert spec.metadata["allbert.permissions"] == "memory_write"
    assert spec.diagnostics == []
  end

  test "invalid YAML is returned as a diagnostic" do
    assert {:error, [diagnostic]} = Parser.parse_dir(fixture("invalid-yaml"))

    assert diagnostic.severity == :error
    assert diagnostic.code == :invalid_yaml
    assert diagnostic.path =~ "invalid-yaml/SKILL.md"
  end

  test "missing required fields skip the skill with structured diagnostics" do
    assert {:error, [diagnostic]} = Parser.parse_dir(fixture("missing-description"))

    assert diagnostic.severity == :error
    assert diagnostic.code == :missing_required_field
    assert diagnostic.field == "description"
  end

  test "parse_many reports duplicate names without crashing" do
    result = Parser.parse_many([fixture("duplicate-one"), fixture("duplicate-two")])

    assert Enum.map(result.specs, & &1.name) == ["duplicate-skill", "duplicate-skill"]

    assert result.diagnostics
           |> Enum.filter(&(&1.code == :duplicate_skill_name))
           |> length() == 2
  end

  test "resources are inventoried without returning resource contents" do
    assert {:ok, spec} = Parser.parse_dir(fixture("resourceful-skill"))

    assert [
             %Resource{path: "assets/example.txt", kind: :asset, byte_size: 12},
             %Resource{path: "references/example.md", kind: :reference, byte_size: byte_size}
           ] = spec.resources

    assert byte_size > 0
    assert Enum.all?(spec.resources, &Regex.match?(~r/^[a-f0-9]{64}$/, &1.sha256))
    refute inspect(spec.resources) =~ "Reference files are inventoried"
  end

  test "script files are listed as inert resources" do
    assert {:ok, spec} = Parser.parse_dir(fixture("scripted-skill"))

    assert [%Resource{path: "scripts/example.sh", kind: :script}] = spec.resources
    assert Enum.any?(spec.diagnostics, &(&1.code == :script_resource_inert))
  end

  defp fixture(name), do: Path.join(@fixtures, name)
end
