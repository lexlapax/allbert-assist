defmodule AllbertAssist.Models.ClosedRuleEvidenceTest do
  use ExUnit.Case, async: true

  @moduletag :pure_async

  alias AllbertAssist.Models.ClosedRuleEvidence

  test "defines one shared violation and non-applicability meaning for providers" do
    semantics = ClosedRuleEvidence.violation_semantics()

    assert ClosedRuleEvidence.transport_version() == 2
    assert semantics =~ "returned final output after any revision"
    assert semantics =~ "true only when"
    assert semantics =~ "false when it satisfies"
    assert semantics =~ "triggering condition does not apply"
  end

  test "builds one closed required Boolean property per immutable rule" do
    assert ClosedRuleEvidence.schema!(~w[first_rule second_rule]) == %{
             "type" => "object",
             "properties" => %{
               "first_rule" => %{
                 "type" => "boolean",
                 "description" =>
                   "For rule first_rule, true means the rule remains violated in the returned final output after any revision; false means the rule is satisfied or not applicable to that final output."
               },
               "second_rule" => %{
                 "type" => "boolean",
                 "description" =>
                   "For rule second_rule, true means the rule remains violated in the returned final output after any revision; false means the rule is satisfied or not applicable to that final output."
               }
             },
             "required" => ["first_rule", "second_rule"],
             "additionalProperties" => false
           }
  end

  test "rejects malformed or duplicate schema rule identifiers" do
    for rule_ids <- [[], ["first_rule", "first_rule"], ["first_rule", ""], [:first_rule]] do
      assert_raise ArgumentError, fn -> ClosedRuleEvidence.schema!(rule_ids) end
    end

    assert_raise ArgumentError, fn -> ClosedRuleEvidence.schema!(%{"first_rule" => true}) end
  end

  test "derives ordered rule results and the aggregate verdict locally" do
    assert {:ok,
            %{
              verdict: "unresolved",
              failed_rule_ids: ["second_rule"],
              rule_results: [
                %{"rule_id" => "first_rule", "verdict" => "satisfied"},
                %{"rule_id" => "second_rule", "verdict" => "unsatisfied"}
              ]
            }} =
             ClosedRuleEvidence.normalize(
               ~w[first_rule second_rule],
               %{"second_rule" => true, "first_rule" => false}
             )
  end

  test "normalizes equivalent atom-keyed judgments without changing catalog order" do
    assert {:ok,
            %{
              verdict: "accepted",
              failed_rule_ids: [],
              rule_results: [
                %{"rule_id" => "first_rule", "verdict" => "satisfied"},
                %{"rule_id" => "second_rule", "verdict" => "satisfied"}
              ]
            }} =
             ClosedRuleEvidence.normalize(
               ~w[first_rule second_rule],
               %{second_rule: false, first_rule: false}
             )
  end

  test "fails closed on incomplete, extra, non-Boolean, or colliding evidence" do
    rule_ids = ~w[first_rule second_rule]

    for violations <- [
          %{"first_rule" => false},
          %{"first_rule" => false, "second_rule" => false, "extra" => false},
          %{"first_rule" => false, "second_rule" => "false"},
          %{:first_rule => false, "first_rule" => false, "second_rule" => false}
        ] do
      assert {:error, :invalid_closed_rule_evidence} =
               ClosedRuleEvidence.normalize(rule_ids, violations)
    end
  end
end
