defmodule AllbertAssist.Intent.DecomposerTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Decomposer
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

  test "splits numbered lists and ordered chains without consulting a model" do
    assert {:fanout, ["Research alpha", "Draft beta"]} =
             Decomposer.propose("1. Research alpha\n2. Draft beta",
               model_proposer: RecordingProposer
             )

    assert {:fanout, ["Research alpha", "draft beta"]} =
             Decomposer.propose("Research alpha and then draft beta",
               model_proposer: RecordingProposer
             )

    refute_received {:model_consulted, _text}
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
               model_proposer: RecordingProposer
             )

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
