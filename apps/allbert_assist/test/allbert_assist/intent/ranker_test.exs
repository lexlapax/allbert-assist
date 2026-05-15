defmodule AllbertAssist.Intent.RankerTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Intent.Ranker

  test "active app boosts matching app candidates when context is app-specific" do
    stocksage =
      EvalFixtures.candidate(
        kind: :skill,
        id: "stocksage-analysis",
        skill_name: "stocksage-analysis",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :stocksage
      )

    allbert =
      EvalFixtures.candidate(
        kind: :skill,
        id: "allbert-help",
        skill_name: "allbert-help",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.3,
        app_id: :allbert
      )

    assert [%{id: "stocksage-analysis"} | _rest] =
             Ranker.rank([allbert, stocksage], %{active_app: :stocksage})
  end

  test "neutral allbert context does not boost app-specific candidates" do
    stocksage =
      EvalFixtures.candidate(
        kind: :skill,
        id: "stocksage-analysis",
        skill_name: "stocksage-analysis",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :stocksage
      )

    allbert =
      EvalFixtures.candidate(
        kind: :skill,
        id: "allbert-help",
        skill_name: "allbert-help",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.3,
        app_id: :allbert
      )

    assert [%{id: "allbert-help"} | _rest] =
             Ranker.rank([allbert, stocksage], %{active_app: :allbert})
  end

  test "surface navigation text boosts matching registered surface candidates" do
    surface =
      EvalFixtures.candidate(
        kind: :surface,
        id: "allbert:agent",
        label: "Allbert Chat",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.1,
        app_id: :allbert,
        surface_id: :agent,
        trace_metadata: %{path: "/agent"}
      )

    assert [%{kind: :surface, id: "allbert:agent"} = ranked] =
             Ranker.rank([surface], %{text: "Open Allbert chat"})

    assert ranked.score > surface.score
    assert ranked.trace_metadata.ranking_reason == :surface_text_match
  end
end
