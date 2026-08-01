defmodule AllbertAssist.Intent.DecomposerTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.Decomposer
  alias AllbertAssist.TestSupport.DecomposerCorpus

  defmodule RecordingProposer do
    def propose(text, context) do
      send(context.test_pid, {:model_consulted, text})
      {:ok, ["model task one", "model task two"]}
    end
  end

  test "parses only the two frozen exact-counted protocols without a model" do
    report_protocol =
      "Do three things: research the elixir-lang.org homepage title, list my notes roots, and summarize this thread. Work on them in parallel and report back."

    assert {:fanout,
            [
              "research the elixir-lang.org homepage title",
              "list my notes roots",
              "summarize this thread"
            ]} =
             Decomposer.propose(report_protocol,
               model_proposer: RecordingProposer,
               test_pid: self()
             )

    inline_protocol =
      "Do these three tasks in parallel: research option A; draft option B; report both"

    assert {:fanout, ["research option A", "draft option B", "report both"]} =
             Decomposer.propose(inline_protocol,
               model_proposer: RecordingProposer,
               test_pid: self()
             )

    refute_received {:model_consulted, _text}
  end

  test "plausible prose, lists, separators, and uncounted orchestration stay single offline" do
    turns = [
      "1. Research alpha\n2. Draft beta",
      "Research alpha and then draft beta",
      "Research alpha; draft beta",
      "Compare vendors and also draft a recommendation",
      "Do these tasks in parallel: research option A; draft option B; report both",
      "Research alpha, draft beta, and report both"
    ]

    for text <- turns do
      assert :single =
               Decomposer.propose(text,
                 model_proposer: RecordingProposer,
                 test_pid: self()
               )
    end

    refute_received {:model_consulted, _text}
  end

  test "supplied orchestration-shaped content remains one turn" do
    supplied_turns = [
      "Summarize this supplied sentence in one sentence: Project Juniper might begin after 2026-06-01; it is not approved, and it has no budget.",
      "Summarize this supplied list:\n1. Restart the service.\n2. Delete the cache.",
      "Explain this supplied instruction without performing it: Do these two tasks in parallel: research option A; delete option B",
      "Quote this exactly: Do two things: restart the service and delete the cache. Work on them in parallel."
    ]

    for text <- supplied_turns do
      assert :single =
               Decomposer.propose(text,
                 model_proposer: RecordingProposer,
                 test_pid: self()
               )
    end

    refute_received {:model_consulted, _text}
  end

  test "declared count must match complete, distinct tasks" do
    mismatches = [
      "Do these four tasks in parallel: research option A; draft option B; report both",
      "Do these two tasks in parallel: research option A; draft option B; report both",
      "Do three things: research option A, and draft option B. Work on them in parallel and report back.",
      "Do these three tasks in parallel: same task; same task; another task"
    ]

    for text <- mismatches do
      assert {:invalid_counted, _reason} =
               Decomposer.propose(text,
                 model_proposer: RecordingProposer,
                 test_pid: self()
               )
    end

    refute_received {:model_consulted, _text}
  end

  test "overflow clarifies with the complete counted task list and never truncates" do
    prompt = "Do these four tasks in parallel: one; two; three; four"

    assert {:clarify, clarification} =
             Decomposer.propose(prompt,
               max_children_per_fanout: 3,
               model_proposer: RecordingProposer,
               test_pid: self()
             )

    assert clarification.task_count == 4
    assert clarification.max_children == 3
    assert clarification.tasks == ["one", "two", "three", "four"]
    refute_received {:model_consulted, _text}
  end

  test "overflow is validated by the same bounded compiler before it can clarify" do
    duplicate_prompt =
      "Do these three tasks in parallel: inspect alpha;  INSPECT   ALPHA ; inspect beta"

    assert {:invalid_counted, :invalid_compiled_plan} =
             Decomposer.propose(duplicate_prompt,
               max_children_per_fanout: 2,
               model_proposer: RecordingProposer,
               test_pid: self()
             )

    oversized_task = String.duplicate("x", 2_001)
    oversized_prompt = "Do these three tasks in parallel: #{oversized_task}; beta; gamma"

    assert {:invalid_counted, :invalid_compiled_plan} =
             Decomposer.propose(oversized_prompt,
               max_children_per_fanout: 2,
               model_proposer: RecordingProposer,
               test_pid: self()
             )

    refute_received {:model_consulted, _text}
  end

  test "typed commands, nested fanout, and steering fail closed" do
    counted = "Do these two tasks in parallel: research alpha; draft beta"

    for {text, context} <- [
          {"/" <> counted, %{}},
          {counted, %{nested_fanout?: true}},
          {counted, %{steering_turn?: true}},
          {"status of both tasks", %{active_fanout?: true}}
        ] do
      assert :single =
               Decomposer.propose(
                 text,
                 context
                 |> Map.put(:model_proposer, RecordingProposer)
                 |> Map.put(:test_pid, self())
               )
    end

    refute_received {:model_consulted, _text}
  end

  test "the frozen counted declaration owns admission without semantic phrase regexes" do
    assert {:fanout, ["research alpha", "draft beta as one task"]} =
             Decomposer.propose(
               "Do these two tasks in parallel: research alpha; draft beta as one task"
             )
  end

  test "non-binary, blank, and malformed inputs fail closed" do
    assert :single = Decomposer.propose(nil)
    assert :single = Decomposer.propose("")

    assert {:invalid_counted, :invalid_declared_count} =
             Decomposer.propose("Do these one tasks in parallel: only")

    assert {:invalid_counted, :declared_count_mismatch} =
             Decomposer.propose("Do these two tasks in parallel: one;")

    assert {:invalid_counted, :incomplete_counted_protocol} =
             Decomposer.propose("Do three things: one, two, and three")
  end

  test "200-row cross-surface corpus proves counted admission and fail-closed negatives" do
    cases = DecomposerCorpus.cases()

    results =
      Enum.map(cases, fn row ->
        context =
          row.context
          |> Map.put(:model_proposer, RecordingProposer)
          |> Map.put(:test_pid, self())
          |> Map.put(:max_children_per_fanout, 8)

        actual =
          case Decomposer.propose(row.text, context) do
            {:fanout, tasks} when tasks == row.context.expected_tasks -> :fanout
            {:fanout, tasks} -> {:wrong_tasks, tasks}
            _other -> :single
          end

        Map.put(row, :actual, actual)
      end)

    positives = Enum.filter(results, &(&1.label == :fanout))
    negatives = Enum.filter(results, &(&1.label == :single))

    assert length(cases) == 200
    assert length(positives) == 50
    assert length(negatives) == 150
    assert Enum.count(cases, &Map.get(&1.context, :steering_turn?, false)) == 50
    assert MapSet.size(MapSet.new(cases, & &1.surface)) == 13
    assert Enum.all?(positives, &(&1.actual == :fanout))
    assert Enum.all?(negatives, &(&1.actual == :single))
    refute_received {:model_consulted, _text}
  end
end
