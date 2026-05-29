defmodule AllbertAssist.Skills.Online.AuditTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Skills.Online.Audit

  test "audits skill metadata and inert resources" do
    audit =
      Audit.run(%{
        source_url: "https://skills.sh/vercel-labs/skills/find-skills",
        skill_md: skill_md(),
        files: %{
          "SKILL.md" => skill_md(),
          "scripts/search.js" => "console.log('search');",
          "package.json" => "{}"
        }
      })

    assert audit.status == :passed
    assert audit.import_eligible?
    assert audit.skill_name == "find-skills"
    assert audit.scripts_present?
    assert audit.package_manifests == ["package.json"]
    assert :scripts_present in audit.warnings
    assert :package_manifest_present in audit.warnings
    assert audit.external_links == ["https://skills.sh/"]
  end

  test "marks missing SKILL.md as ineligible" do
    audit = Audit.run(%{files: %{}})

    assert audit.status == :failed
    refute audit.import_eligible?
    assert [%{code: :missing_skill_md}] = audit.diagnostics
  end

  defp skill_md do
    """
    ---
    name: find-skills
    description: Find skills from https://skills.sh/.
    ---

    Use a registry token only if the operator configured one.
    """
  end
end
