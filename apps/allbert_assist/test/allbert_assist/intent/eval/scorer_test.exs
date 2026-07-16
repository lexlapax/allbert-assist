defmodule AllbertAssist.Intent.Eval.ScorerTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Eval.Corpus
  alias AllbertAssist.Intent.Eval.Scorer

  test "computes accuracy, confusion, slots, clarify/execute, and negatives" do
    run = %{
      results: [
        result(
          case!("stocks-analyze-001", "stocks", :execute, "run_analysis", %{"ticker" => :present}),
          %{
            kind: :execute,
            action: "run_analysis",
            slots: %{ticker: "AAPL"}
          }
        ),
        result(case!("notes-ambiguous-001", "notes", :clarify, nil), %{kind: :clarify}),
        result(
          case!("operator-negative-001", "operator", :execute, "intent_doctor", %{}, true),
          %{
            kind: :execute,
            action: "intent_doctor"
          }
        )
      ]
    }

    score = Scorer.score(run)

    assert score.total == 3
    assert score.passed == 2
    assert score.overall_accuracy == 0.6667
    assert score.per_domain["stocks"].accuracy == 1.0
    assert score.slot_accuracy == %{total: 1, passed: 1, accuracy: 1.0}
    assert score.clarify_vs_execute == %{total: 3, passed: 2, accuracy: 0.6667}

    assert [%{id: "operator-negative-001", actual_action: "intent_doctor"}] =
             score.negative_violations

    assert %{expected: "execute:intent_doctor", actual: "execute:intent_doctor", count: 1} in score.confusion
  end

  test "reports regressions against a baseline score" do
    run = %{
      results: [
        result(
          case!("notes-create-001", "notes", :execute, "write_note", %{"title" => :present}),
          %{kind: :none}
        )
      ]
    }

    baseline = %{
      id: "before",
      overall_accuracy: 1.0,
      per_domain: %{"notes" => %{accuracy: 1.0}},
      slot_accuracy: %{accuracy: 1.0},
      clarify_vs_execute: %{accuracy: 1.0}
    }

    score = Scorer.score(run, baseline)

    assert score.gate.baseline == "before"
    assert %{metric: :overall_accuracy, previous: 1.0, current: 0.0} in score.gate.regressions
    assert %{metric: :slot_accuracy, previous: 1.0, current: 0.0} in score.gate.regressions

    assert %{metric: :clarify_vs_execute_accuracy, previous: 1.0, current: 0.0} in score.gate.regressions

    assert %{metric: :per_domain_accuracy, domain: "notes", previous: 1.0, current: 0.0} in score.gate.regressions
  end

  test "negative cases default to no execution, with explicit forbidden-action mode available" do
    no_execute_case =
      case!("operator-negative-001", "operator", :execute, "intent_doctor", %{}, true)

    forbidden_action_case =
      case!(%{
        id: "operator-forbidden-action-001",
        domain: "operator",
        utterance: "operator-forbidden-action-001",
        expected: %{kind: :execute, action: "intent_doctor"},
        negative: true,
        negative_mode: :forbidden_action
      })

    score =
      Scorer.score(%{
        results: [
          result(no_execute_case, %{kind: :execute, action: "preview_plan"}),
          result(forbidden_action_case, %{kind: :execute, action: "preview_plan"})
        ]
      })

    assert [
             %{
               id: "operator-negative-001",
               negative_mode: :no_execute,
               forbidden_action: "intent_doctor",
               actual_action: "preview_plan"
             }
           ] = score.negative_violations

    assert score.passed == 1
  end

  defp result(case, actual), do: %{case: case, actual: actual}

  defp case!(attrs) when is_map(attrs) do
    {:ok, case} = Corpus.validate(attrs)
    case
  end

  defp case!(id, domain, kind, action, slots \\ %{}, negative? \\ false) do
    case!(%{
      id: id,
      domain: domain,
      utterance: id,
      expected: %{kind: kind, action: action, slots: slots},
      negative: negative?
    })
  end
end
