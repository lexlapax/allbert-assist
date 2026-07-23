defmodule AllbertAssist.Intent.SteeringTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Intent.Steering
  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout

  setup do
    {:ok, fanout} =
      Fanout.frame(
        %{user_id: "alice", source_thread_id: "thread-1", title: "Work", objective: "Work"},
        ["Research weather risks", "Draft launch brief", "Check budget"]
      )

    %{parent: fanout.parent, children: fanout.children}
  end

  test "classifies status, high-confidence cancel, steering, and unrelated requests", ctx do
    assert {:status, children} = Steering.classify("status", [ctx.parent])
    assert length(children) == 3
    assert {:cancel, [second]} = Steering.classify("cancel the second task", [ctx.parent])
    assert second.title == "Draft launch brief"

    assert {:steer, [first]} =
             Steering.classify("change research one to focus on rain", [ctx.parent])

    assert first.title == "Research weather risks"

    assert {:adjust, [first]} =
             Steering.classify("refine research weather risks with citations", [ctx.parent])

    assert first.title == "Research weather risks"
    assert :new_request = Steering.classify("what is the weather?", [ctx.parent])
  end

  test "mutations clarify missing or ambiguous targets", ctx do
    assert {:clarify, _} = Steering.classify("cancel", [ctx.parent])
    assert {:clarify, _} = Steering.classify("change task", [ctx.parent])
  end

  test "free text and typed confirmation commands never become steering approval", ctx do
    for text <- ["yes", "looks good", "approve confirmation conf_123", "deny conf_123"] do
      assert :new_request = Steering.classify(text, [ctx.parent])
    end
  end

  test "optional model assist is advisory and cannot bypass target clarification", ctx do
    assist = fn _text, _children -> :cancel end

    assert {:clarify, _} =
             Steering.classify("could you end that work?", [ctx.parent], model_assist: assist)

    new_request = fn _text, _children -> :new_request end

    assert :new_request =
             Steering.classify("could you end that work?", [ctx.parent],
               model_assist: new_request
             )
  end

  test "handle scopes targets to the current user and thread", ctx do
    {:ok, other_thread} =
      Fanout.frame(
        %{user_id: "alice", source_thread_id: "thread-2", title: "Other", objective: "Other"},
        ["Other first", "Other second"]
      )

    {:ok, foreign} =
      Fanout.frame(
        %{
          user_id: "mallory",
          source_thread_id: "thread-1",
          title: "Foreign",
          objective: "Foreign"
        },
        ["Foreign first", "Foreign second"]
      )

    assert {:ok, _response} =
             Steering.handle(%{
               text: "adjust first to add citations",
               user_id: "alice",
               thread_id: "thread-1",
               channel: :test,
               coding_turn?: false
             })

    own_first = hd(Fanout.children(ctx.parent))
    assert Enum.any?(Objectives.list_events(own_first.id), &(&1.kind == "steer_directive"))
    assert Enum.all?(Fanout.children(other_thread.parent), &(&1.status == "open"))
    assert Enum.all?(Fanout.children(foreign.parent), &(&1.status == "open"))
  end

  test "reviewable varied corpus meets per-class precision and recall floors", ctx do
    rows = steering_corpus()
    assert length(rows) == 150
    assert rows |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> length() == 150

    results =
      Enum.map(rows, fn {expected, text} ->
        actual =
          case Steering.classify(text, [ctx.parent]) do
            {kind, _} -> kind
            kind -> kind
          end

        {expected, actual}
      end)

    metrics =
      for label <- [:status, :cancel, :steer, :adjust, :new_request] do
        true_positives = Enum.count(results, &(&1 == {label, label}))
        predicted = Enum.count(results, fn {_expected, actual} -> actual == label end)
        expected = Enum.count(results, fn {expected, _actual} -> expected == label end)
        precision = true_positives / max(predicted, 1)
        recall = true_positives / max(expected, 1)
        assert precision >= 0.90, "#{label} precision below floor"
        assert recall >= 0.90, "#{label} recall below floor"
        %{label: label, precision: precision, recall: recall}
      end

    assert Enum.sum(Enum.map(metrics, & &1.precision)) / length(metrics) >= 0.90
    assert Enum.sum(Enum.map(metrics, & &1.recall)) / length(metrics) >= 0.90

    cancel_predictions = Enum.filter(results, fn {_expected, actual} -> actual == :cancel end)
    assert Enum.all?(cancel_predictions, fn {expected, _} -> expected == :cancel end)

    confirmation_text =
      results
      |> Enum.zip(rows)
      |> Enum.filter(fn {_result, {_expected, text}} ->
        Regex.match?(~r/(?:approve|deny|yes go ahead|looks good|approved|do it)/iu, text)
      end)

    assert confirmation_text != []

    assert Enum.all?(confirmation_text, fn {{_expected, actual}, _row} ->
             actual == :new_request
           end)
  end

  defp steering_corpus do
    targets = ["first", "second", "third", "research weather risks", "draft launch brief"]

    classified =
      [
        status: ["status", "progress", "how is", "what is the status of", "status update for"],
        cancel: ["cancel", "stop", "skip", "cancel work on", "stop processing"],
        steer: ["steer", "change", "redirect", "revise", "make a different goal for"],
        adjust: ["adjust", "refine", "tweak", "shorten", "add citations to"]
      ]
      |> Enum.flat_map(fn {label, phrases} ->
        for {phrase, phrase_index} <- Enum.with_index(phrases),
            {target, target_index} <- Enum.with_index(targets) do
          {label, "#{phrase} #{target} variant #{phrase_index * 5 + target_index + 1}"}
        end
      end)

    new_requests =
      for index <- 1..25,
          do: {:new_request, "write a separate new request number #{index} about garden planning"}

    ambiguous_or_unknown =
      [
        "cancel both first and second",
        "change first and second",
        "adjust first and third",
        "stop research weather risks and draft launch brief",
        "redirect first plus second",
        "cancel the unknown workstream",
        "adjust the missing analysis",
        "steer nonexistent task",
        "stop an unnamed child",
        "refine that one over there"
      ]
      |> Enum.map(&{:clarify, &1})

    confirmation_and_unrelated =
      [
        "yes go ahead",
        "looks good",
        "please continue",
        "approved",
        "do it",
        "approve confirmation conf_123",
        "deny conf_123",
        "ALLBERT:APPROVE:conf_123",
        "ALLBERT:DENY:conf_123",
        "please approve confirmation conf_123",
        "status and cancel first",
        "new request cancel culture essay",
        "email the first draft",
        "compare first principles",
        "research the second-order effects"
      ]
      |> Enum.map(&{:new_request, &1})

    classified ++ new_requests ++ ambiguous_or_unknown ++ confirmation_and_unrelated
  end
end
