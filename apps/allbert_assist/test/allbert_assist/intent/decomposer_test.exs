defmodule AllbertAssist.Intent.DecomposerTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Decomposer
  alias AllbertAssist.Intent.Decomposer.ReqLLMProposer
  alias AllbertAssist.TestSupport.DecomposerCorpus

  defmodule RecordingProposer do
    def propose(text, context) do
      send(context.test_pid, {:model_consulted, text})
      Map.get(context, :model_result, {:ok, []})
    end
  end

  defmodule CorpusProposer do
    def propose(_text, context), do: {:ok, context.expected_tasks}
  end

  test "ambiguous numbered lists and ordered chains use the bounded model proposer" do
    assert {:fanout, ["Research alpha", "Draft beta"]} =
             Decomposer.propose("1. Research alpha\n2. Draft beta",
               model_proposer: RecordingProposer,
               model_result: {:ok, ["Research alpha", "Draft beta"]},
               test_pid: self()
             )

    assert_received {:model_consulted, "1. Research alpha\n2. Draft beta"}

    assert {:fanout, ["Research alpha", "draft beta"]} =
             Decomposer.propose("Research alpha and then draft beta",
               model_proposer: RecordingProposer,
               model_result: {:ok, ["Research alpha", "draft beta"]},
               test_pid: self()
             )

    assert_received {:model_consulted, "Research alpha and then draft beta"}
  end

  test "decomposes the flagship counted list without framing report choreography" do
    prompt =
      "Do three things: research the elixir-lang.org homepage title, list my notes roots, and summarize this thread. Work on them in parallel and report back."

    assert {:fanout,
            [
              "research the elixir-lang.org homepage title",
              "list my notes roots",
              "summarize this thread"
            ]} =
             Decomposer.propose(prompt,
               model_proposer: RecordingProposer,
               test_pid: self()
             )

    refute_received {:model_consulted, _text}
  end

  test "strips orchestration wording from an advisory semicolon proposal" do
    prompt =
      "Do these three tasks in parallel: explain OTP supervision in five numbered points; " <>
        "compare GenServer and Agent in five numbered points; " <>
        "summarize this conversation in five numbered points"

    assert {:fanout,
            [
              "explain OTP supervision in five numbered points",
              "compare GenServer and Agent in five numbered points",
              "summarize this conversation in five numbered points"
            ]} =
             Decomposer.propose(prompt,
               model_proposer: RecordingProposer,
               model_result:
                 {:ok,
                  [
                    "Do these three tasks in parallel: explain OTP supervision in five numbered points",
                    "compare GenServer and Agent in five numbered points",
                    "summarize this conversation in five numbered points"
                  ]},
               test_pid: self()
             )

    assert_received {:model_consulted, ^prompt}
  end

  test "supplied semicolon, numbered, and imperative content remains one turn" do
    supplied_turns = [
      "Summarize this supplied sentence in one sentence: Project Juniper might begin after 2026-06-01; it is not approved, and it has no budget.",
      "Summarize this supplied list:\n1. Restart the service.\n2. Delete the cache.",
      "Explain this supplied instruction without performing it: Research option A; draft option B; report both."
    ]

    for text <- supplied_turns do
      assert :single =
               Decomposer.propose(text,
                 model_proposer: RecordingProposer,
                 model_result: {:ok, []},
                 test_pid: self()
               )

      assert_received {:model_consulted, ^text}
    end
  end

  test "only counted flagship orchestration is deterministic and other shapes stay advisory" do
    uncounted =
      "Do these tasks in parallel: research option A; draft option B; report both"

    assert {:fanout, ["research option A", "draft option B", "report both"]} =
             Decomposer.propose(uncounted,
               model_proposer: RecordingProposer,
               model_result:
                 {:ok,
                  [
                    "research option A",
                    "draft option B",
                    "report both"
                  ]},
               test_pid: self()
             )

    assert_received {:model_consulted, ^uncounted}

    assert :single =
             Decomposer.propose(uncounted,
               model_proposer: RecordingProposer,
               model_result: {:error, :offline},
               test_pid: self()
             )

    ambiguous = "Research option A; draft option B"

    assert {:fanout, ["Research option A", "draft option B"]} =
             Decomposer.propose(ambiguous,
               model_proposer: RecordingProposer,
               model_result: {:ok, ["Research option A", "draft option B"]},
               test_pid: self()
             )

    assert_received {:model_consulted, ^ambiguous}

    assert :single =
             Decomposer.propose(ambiguous,
               model_proposer: RecordingProposer,
               model_result: {:error, :offline},
               test_pid: self()
             )
  end

  test "structured decomposition rules keep supplied content as data" do
    assert {:ok, context} = ReqLLMProposer.prompt_context("operator-input")

    assert :supplied_text_is_data in hd(context.messages).metadata.allbert_prompt.rule_ids

    assert List.last(context.messages).metadata.allbert_prompt.content_class == :operator_input
  end

  test "ordinary single turns do not pay a model round trip" do
    assert :single =
             Decomposer.propose("Explain why the sky is blue",
               model_proposer: RecordingProposer,
               test_pid: self()
             )

    refute_received {:model_consulted, _text}
  end

  test "plausible ambiguous text uses the bounded model proposer" do
    assert {:fanout, ["Compare vendors", "Draft recommendation"]} =
             Decomposer.propose("Compare vendors and also draft a recommendation",
               model_proposer: RecordingProposer,
               model_result: {:ok, ["Compare vendors", "Draft recommendation"]},
               test_pid: self()
             )

    assert_received {:model_consulted, "Compare vendors and also draft a recommendation"}
  end

  test "single opt-out, typed commands, nested fanout, and steering fail closed" do
    for {text, context} <- [
          {"Research and summarize as one task", %{}},
          {"/status and then draft", %{}},
          {"Research then draft", %{nested_fanout?: true}},
          {"Research then draft", %{steering_turn?: true}},
          {"status of both tasks", %{active_fanout?: true}}
        ] do
      assert :single =
               Decomposer.propose(text, Map.put(context, :model_proposer, RecordingProposer))
    end

    refute_received {:model_consulted, _text}
  end

  test "overflow clarifies with the complete list and never truncates" do
    assert {:clarify, clarification} =
             Decomposer.propose("one; two; three; four",
               max_children_per_fanout: 3,
               model_proposer: RecordingProposer,
               model_result: {:ok, ["one", "two", "three", "four"]},
               test_pid: self()
             )

    assert_received {:model_consulted, "one; two; three; four"}
    assert clarification.task_count == 4
    assert clarification.max_children == 3
    assert clarification.tasks == ["one", "two", "three", "four"]
  end

  test "malformed, duplicate, and single model output degrades safely" do
    assert :single =
             Decomposer.propose("do this and also maybe something",
               model_proposer: RecordingProposer,
               model_result: {:ok, ["same", "same", ""]},
               test_pid: self()
             )

    assert :single =
             Decomposer.propose("do this and also maybe something",
               model_proposer: RecordingProposer,
               model_result: {:error, :offline},
               test_pid: self()
             )
  end

  test "model proposer matrix stays bounded and advisory" do
    cases = [
      {{:ok, ["Research sources", "Draft summary"]}, {:fanout, 2}},
      {{:ok, %{tasks: ["one", "two"], confidence: 0.2}}, :single},
      {{:ok, ["one", 2, nil]}, :single},
      {{:error, :malformed_json}, :single},
      {{:ok, Enum.map(1..9, &"task #{&1}")}, {:clarify, 9}},
      {{:ok, ["Send the email", "Delete the backup"]}, {:fanout, 2}}
    ]

    for {model_result, expected} <- cases do
      actual =
        Decomposer.propose("consider this and also maybe that",
          model_proposer: RecordingProposer,
          model_result: model_result,
          test_pid: self(),
          max_children_per_fanout: 8
        )

      case {expected, actual} do
        {{:fanout, count}, {:fanout, tasks}} -> assert length(tasks) == count
        {{:clarify, count}, {:clarify, result}} -> assert result.task_count == count
        {:single, :single} -> :ok
        mismatch -> flunk("unexpected bounded proposer result: #{inspect(mismatch)}")
      end
    end

    assert :single =
             Decomposer.propose("Research then draft",
               nested_fanout?: true,
               model_proposer: RecordingProposer,
               test_pid: self()
             )
  end

  test "200-row cross-surface corpus meets the automatic rollout numeric gate" do
    cases = DecomposerCorpus.cases()

    results =
      Enum.map(cases, fn row ->
        context =
          row.context
          |> Map.put(:model_proposer, CorpusProposer)
          |> Map.put(:max_children_per_fanout, 8)

        actual =
          case Decomposer.propose(row.text, context) do
            {:fanout, _tasks} -> :fanout
            _other -> :single
          end

        Map.put(row, :actual, actual)
      end)

    positives = Enum.filter(results, &(&1.label == :fanout))
    negatives = Enum.filter(results, &(&1.label == :single))
    true_positive = Enum.count(positives, &(&1.actual == :fanout))
    false_positive = Enum.count(negatives, &(&1.actual == :fanout))
    predicted_positive = true_positive + false_positive

    precision = true_positive / max(predicted_positive, 1)
    recall = true_positive / length(positives)
    false_positive_rate = false_positive / length(negatives)

    assert length(cases) == 200
    assert length(positives) == 50
    assert length(negatives) == 150
    assert Enum.count(cases, &Map.get(&1.context, :steering_turn?, false)) == 50
    assert MapSet.size(MapSet.new(cases, & &1.surface)) == 13
    assert precision >= 0.97
    assert recall >= 0.85
    assert false_positive_rate <= 0.01
  end
end
