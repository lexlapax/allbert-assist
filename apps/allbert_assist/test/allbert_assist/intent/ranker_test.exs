defmodule AllbertAssist.Intent.RankerTest do
  use ExUnit.Case, async: false
  @moduletag :app_env_serial

  alias AllbertAssist.Intent.EvalFixtures
  alias AllbertAssist.Intent.Ranker
  alias AllbertAssist.Paths
  alias AllbertAssist.Settings

  setup {AllbertAssist.StockSageRegistryCase, :setup}

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths = Application.get_env(:allbert_assist, Paths)
    original_settings = Application.get_env(:allbert_assist, Settings)

    System.put_env(
      "ALLBERT_HOME",
      Path.join(System.tmp_dir!(), "allbert-ranker-#{System.unique_integer([:positive])}")
    )

    Application.delete_env(:allbert_assist, Paths)
    Application.delete_env(:allbert_assist, Settings)

    on_exit(fn ->
      if original_home,
        do: System.put_env("ALLBERT_HOME", original_home),
        else: System.delete_env("ALLBERT_HOME")

      restore(Paths, original_paths)
      restore(Settings, original_settings)
    end)

    :ok
  end

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

  test "descriptor vocabulary phrases are data-driven and can block negative phrases" do
    write_note =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "notes_files:write_note",
        action_name: "write_note",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :notes_files,
        trace_metadata: %{
          descriptor: %{
            label: "Write note",
            action_name: "write_note",
            examples: [],
            synonyms: [],
            vocabulary: %{
              phrases: ["note titled"],
              negative_phrases: ["find my notes"],
              allow_single_token_match: false
            }
          }
        }
      )

    search_notes =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "notes_files:search_notes",
        action_name: "search_notes",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.21,
        app_id: :notes_files,
        trace_metadata: %{
          descriptor: %{
            label: "Search notes",
            action_name: "search_notes",
            examples: ["find my notes"],
            synonyms: ["search notes"]
          }
        }
      )

    assert [%{id: "notes_files:write_note"} = ranked | _rest] =
             Ranker.rank([search_notes, write_note], %{text: "create a note titled chan"})

    assert ranked.trace_metadata.ranking_reason == :descriptor_text_match

    assert [%{id: "notes_files:search_notes"} | _rest] =
             Ranker.rank([search_notes, write_note], %{text: "find my notes about goals"})
  end

  test "descriptor text matching tolerates small grammar gaps" do
    write_note =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "notes_files:write_note",
        action_name: "write_note",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :notes_files,
        trace_metadata: %{
          descriptor: %{
            label: "Create or write a local note",
            action_name: "write_note",
            examples: ["create a note titled groceries with body milk and eggs"],
            synonyms: ["create note", "write note", "save note"]
          }
        }
      )

    search_notes =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "notes_files:search_notes",
        action_name: "search_notes",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :notes_files,
        trace_metadata: %{
          descriptor: %{
            label: "Search local notes",
            action_name: "search_notes",
            examples: ["find notes about onboarding"],
            synonyms: ["search notes", "find notes"]
          }
        }
      )

    assert [%{id: "notes_files:write_note"} = ranked | _rest] =
             Ranker.rank([search_notes, write_note], %{
               text: "create a note titled fallback with body hi"
             })

    assert ranked.trace_metadata.ranking_reason == :descriptor_text_match
  end

  test "descriptor text boost reads Settings Central scoring values" do
    write_note =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "notes_files:write_note",
        action_name: "write_note",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :notes_files,
        trace_metadata: %{
          descriptor: %{
            label: "Create or write a local note",
            action_name: "write_note",
            examples: ["create a note titled groceries"],
            synonyms: ["create note"]
          }
        }
      )

    search_notes =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "notes_files:search_notes",
        action_name: "search_notes",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.4,
        app_id: :notes_files,
        trace_metadata: %{
          descriptor: %{
            label: "Search notes",
            action_name: "search_notes",
            examples: ["find notes"],
            synonyms: ["search notes"]
          }
        }
      )

    assert [%{id: "notes_files:write_note"} | _rest] =
             Ranker.rank([search_notes, write_note], %{text: "create a note titled release"})

    {:ok, _} = Settings.put("intent.router_scoring.ranker.descriptor_text_match_boost", 0.0)

    {:ok, _} =
      Settings.put("intent.router_scoring.ranker.descriptor_text_match_unit_boost", 0.0)

    assert [%{id: "notes_files:search_notes"} | _rest] =
             Ranker.rank([search_notes, write_note], %{text: "create a note titled release"})
  end

  test "descriptor matching prefers exact phrases over generic words in labels" do
    run_analysis =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "stocksage:run_analysis",
        label: "Run StockSage analysis",
        action_name: "run_analysis",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :stocksage,
        trace_metadata: %{
          descriptor: %{
            label: "Run StockSage analysis",
            action_name: "run_analysis",
            examples: ["analyze AAPL"],
            synonyms: ["analyze", "stock analysis"]
          }
        }
      )

    queue_analysis =
      EvalFixtures.candidate(
        kind: :app_intent,
        id: "stocksage:queue_analysis",
        label: "Queue StockSage analysis",
        action_name: "queue_analysis",
        source: :app,
        status: :candidate,
        selected?: false,
        score: 0.2,
        app_id: :stocksage,
        trace_metadata: %{
          descriptor: %{
            label: "Queue StockSage analysis",
            action_name: "queue_analysis",
            examples: ["queue analysis for AAPL"],
            synonyms: ["queue analysis", "add to queue"]
          }
        }
      )

    assert [%{id: "stocksage:queue_analysis"} = ranked | rest] =
             Ranker.rank([run_analysis, queue_analysis], %{text: "queue analysis for AAPL"})

    assert ranked.trace_metadata.ranking_reason == :descriptor_text_match

    assert Enum.all?(
             rest,
             &(Map.get(&1.trace_metadata, :ranking_reason) != :descriptor_text_match)
           )
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

  defp restore(key, nil), do: Application.delete_env(:allbert_assist, key)
  defp restore(key, value), do: Application.put_env(:allbert_assist, key, value)
end
