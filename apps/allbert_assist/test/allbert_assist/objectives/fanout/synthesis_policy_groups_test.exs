defmodule AllbertAssist.Objectives.Fanout.SynthesisPolicyGroupsTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.Report.SynthesisPolicy

  @catalog_digest_domain "allbert:fanout-synthesis-rule-groups:v1\0"
  @catalog_sha256 "61ac97566994fff0e0f83d8ef7f9cdef6d1c9a185f1a734d4043764a395e8de9"

  test "group catalog v1 is the exact nonempty disjoint rule cover in policy order" do
    assert SynthesisPolicy.rule_group_catalog_version() == 1

    assert {:ok, groups} = SynthesisPolicy.rule_groups(1)

    assert groups == [
             %{
               "id" => "coverage_relationship",
               "rule_ids" => [
                 "complete_child_coverage",
                 "parent_join_request_coverage",
                 "relationship_support"
               ]
             },
             %{
               "id" => "integrity_authority",
               "rule_ids" => [
                 "internal_consistency",
                 "uncertainty_marking",
                 "no_effect_or_authority_claims",
                 "one_paragraph_presentation"
               ]
             }
           ]

    assert Enum.all?(groups, &(&1["rule_ids"] != []))

    grouped_rule_ids = Enum.flat_map(groups, & &1["rule_ids"])

    assert grouped_rule_ids == SynthesisPolicy.rule_ids()
    assert Enum.uniq(grouped_rule_ids) == grouped_rule_ids
  end

  test "group catalog v1 digest binds its canonical ordered data" do
    assert {:ok, groups} = SynthesisPolicy.rule_groups(1)

    expected_sha256 =
      @catalog_digest_domain
      |> Kernel.<>(CanonicalJSON.encode(groups))
      |> sha256()

    assert {:ok, ^expected_sha256} = SynthesisPolicy.rule_group_catalog_sha256(1)
    assert expected_sha256 == @catalog_sha256
    assert expected_sha256 =~ ~r/\A[0-9a-f]{64}\z/
  end

  test "unsupported group catalog versions are rejected" do
    assert {:error, :unsupported_rule_group_catalog_version} =
             SynthesisPolicy.rule_groups(2)

    assert {:error, :unsupported_rule_group_catalog_version} =
             SynthesisPolicy.rule_group_catalog_sha256(2)
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
