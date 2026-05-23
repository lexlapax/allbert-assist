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
        id: "allbert:workspace",
        label: "Allbert Chat",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.1,
        app_id: :allbert,
        surface_id: :workspace,
        trace_metadata: %{path: "/workspace"}
      )

    assert [%{kind: :surface, id: "allbert:workspace"} = ranked] =
             Ranker.rank([surface], %{text: "Open Allbert chat"})

    assert ranked.score > surface.score
    assert ranked.trace_metadata.ranking_reason == :surface_text_match
  end

  test "action and skill text matches boost matching candidates" do
    list_skills =
      EvalFixtures.candidate(
        kind: :action,
        id: "list_skills",
        action_name: "list_skills",
        source: :registry,
        status: :candidate,
        selected?: false,
        score: 0.2
      )

    direct_answer =
      EvalFixtures.candidate(
        kind: :action,
        id: "direct_answer",
        action_name: "direct_answer",
        source: :registry,
        status: :candidate,
        selected?: false,
        score: 0.25
      )

    assert [%{id: "list_skills"} = ranked | _rest] =
             Ranker.rank([direct_answer, list_skills], %{text: "list my skills"})

    assert ranked.trace_metadata.ranking_reason == :action_text_match
  end

  test "channel and job keywords boost their candidate kinds" do
    channel =
      EvalFixtures.candidate(
        kind: :channel,
        id: "telegram",
        channel_id: "telegram",
        label: "telegram_bot_api",
        source: :channel,
        status: :candidate,
        selected?: false,
        score: 0.1
      )

    job =
      EvalFixtures.candidate(
        kind: :job,
        id: "job_1",
        job_id: "job_1",
        label: "daily brief",
        source: :job,
        status: :candidate,
        selected?: false,
        score: 0.1
      )

    assert [%{id: "telegram"} = ranked_channel] =
             Ranker.rank([channel], %{text: "show telegram channels"})

    assert ranked_channel.trace_metadata.ranking_reason == :channel_text_match

    assert [%{id: "job_1"} = ranked_job] =
             Ranker.rank([job], %{text: "show scheduled jobs"})

    assert ranked_job.trace_metadata.ranking_reason == :job_text_match
  end
end
