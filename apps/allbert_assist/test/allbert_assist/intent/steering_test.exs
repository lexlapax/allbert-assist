defmodule AllbertAssist.Intent.SteeringTest do
  use AllbertAssist.DataCase, async: false, lane: :db_serial

  alias AllbertAssist.Intent.Steering
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

  test "corpus meets release thresholds", ctx do
    rows =
      for {label, template} <- [
            status: "status %{target}",
            cancel: "cancel %{target}",
            steer: "change %{target} to include citations",
            new_request: "write a new poem variant %{n}",
            clarify: "cancel the unknown workstream variant"
          ],
          n <- 1..30 do
        target = Enum.at(~w[first second third], rem(n - 1, 3))

        text =
          template
          |> String.replace("%{target}", target)
          |> String.replace("%{n}", Integer.to_string(n))

        {label, text}
      end

    assert length(rows) == 150

    results =
      Enum.map(rows, fn {expected, text} ->
        actual =
          case Steering.classify(text, [ctx.parent]) do
            {kind, _} -> kind
            kind -> kind
          end

        {expected, actual}
      end)

    correct = Enum.count(results, fn {expected, actual} -> expected == actual end)
    assert correct / length(results) >= 0.90

    cancel_predictions = Enum.filter(results, fn {_expected, actual} -> actual == :cancel end)
    assert Enum.all?(cancel_predictions, fn {expected, _} -> expected == :cancel end)
  end
end
