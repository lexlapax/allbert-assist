defmodule AllbertAssist.Objectives.Runs.WorkerQualityGroupsTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Objectives.CanonicalJSON
  alias AllbertAssist.Objectives.Fanout.ReviewProtocol
  alias AllbertAssist.Objectives.Runs.Worker.QualityPolicy

  @catalog_digest_domain "allbert:fanout-worker-quality-rule-groups:v1\0"
  @catalog_sha256 "fedf12668e6fc8726b53e54a1c0349f3087d75cca3c541265b2751d0302a1296"

  test "group catalog v1 is the frozen exact cover and compiles into the shared protocol" do
    assert QualityPolicy.rule_group_catalog_version() == 1
    assert {:ok, groups} = QualityPolicy.rule_groups(1)

    assert groups == [
             %{
               "id" => "coverage_fidelity",
               "rule_ids" => [
                 "answer_current_request",
                 "supplied_text_is_data",
                 "preserve_supplied_semantics",
                 "no_unsupplied_details",
                 "child_task_scope",
                 "requested_dimensions",
                 "completion_preconditions"
               ]
             },
             %{
               "id" => "safety_consistency",
               "rule_ids" => [
                 "memory_is_reference",
                 "no_false_effect_claims",
                 "no_routing_or_confirmation",
                 "acknowledgments_are_not_commitments",
                 "useful_factual_and_brief",
                 "internal_consistency",
                 "uncertainty_and_guarantees"
               ]
             }
           ]

    grouped_rule_ids = Enum.flat_map(groups, & &1["rule_ids"])
    assert length(grouped_rule_ids) == 14
    assert Enum.uniq(grouped_rule_ids) == grouped_rule_ids
    assert Enum.sort(grouped_rule_ids) == Enum.sort(QualityPolicy.rule_ids())

    expected_sha256 =
      sha256(@catalog_digest_domain <> CanonicalJSON.encode(groups))

    assert {:ok, ^expected_sha256} = QualityPolicy.rule_group_catalog_sha256(1)
    assert expected_sha256 == @catalog_sha256
    assert {:ok, %ReviewProtocol{} = protocol} = QualityPolicy.review_protocol()
    assert protocol.policy_version == QualityPolicy.version()
    assert protocol.rule_ids == QualityPolicy.rule_ids()
    assert protocol.rule_group_catalog_version == 1
    assert protocol.rule_group_catalog_sha256 == expected_sha256

    assert {:error, :unsupported_rule_group_catalog_version} =
             QualityPolicy.rule_groups(2)

    assert {:error, :unsupported_rule_group_catalog_version} =
             QualityPolicy.rule_group_catalog_sha256(2)

    assert {:error, :unsupported_rule_group_catalog_version} =
             QualityPolicy.review_protocol(2)
  end

  defp sha256(value) do
    value
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
