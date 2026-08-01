defmodule AllbertAssist.Intent.FanoutPlanTest do
  use ExUnit.Case, async: true
  @moduletag :pure_async

  alias AllbertAssist.Intent.FanoutPlan

  @request "Research the two options independently and compare what you find."

  test "compiles an ordered inert plan and binds it to the exact operator request" do
    children = [
      %{
        "title" => "Research option A",
        "objective" => "Find the documented properties of option A.",
        "expected_result" => "A factual summary with sources."
      },
      %{
        "title" => "Research option B",
        "objective" => "Find the documented properties of option B.",
        "expected_result" => "A factual summary with sources."
      }
    ]

    assert {:ok, plan} = FanoutPlan.compile(@request, children, source: :model)

    assert %FanoutPlan{
             original_request: @request,
             source: :model,
             children: ^children
           } = plan

    assert plan.original_request_sha256 ==
             :crypto.hash(:sha256, @request) |> Base.encode16(case: :lower)

    assert plan.plan_sha256 =~ ~r/^[0-9a-f]{64}$/

    assert FanoutPlan.provenance(plan) == %{
             "version" => 1,
             "source" => "conversation_manager",
             "original_request_sha256" => plan.original_request_sha256,
             "plan_sha256" => plan.plan_sha256
           }

    assert [first, second] = FanoutPlan.child_attrs(plan)

    assert Map.drop(first, [:proposer_hint]) == %{
             title: "Research option A",
             objective: "Find the documented properties of option A.",
             acceptance_criteria: Jason.encode!(%{"summary" => "A factual summary with sources."})
           }

    assert Map.drop(second, [:proposer_hint]) == %{
             title: "Research option B",
             objective: "Find the documented properties of option B.",
             acceptance_criteria: Jason.encode!(%{"summary" => "A factual summary with sources."})
           }

    assert FanoutPlan.child_binding_valid?(
             plan.plan_sha256,
             0,
             Enum.at(children, 0),
             first.proposer_hint
           )

    assert FanoutPlan.child_binding_valid?(
             plan.plan_sha256,
             1,
             Enum.at(children, 1),
             second.proposer_hint
           )

    refute FanoutPlan.child_binding_valid?(
             plan.plan_sha256,
             0,
             Enum.at(children, 1),
             first.proposer_hint
           )
  end

  test "closed child shape rejects authority and orchestration fields" do
    base = %{
      "title" => "Research option A",
      "objective" => "Research option A.",
      "expected_result" => "A factual result."
    }

    for forbidden <- [
          {"action", "browse"},
          {"permission", "allowed"},
          {"confirmation", "not_required"},
          {"id", "chosen-by-model"},
          {"user_id", "other-user"},
          {"depends_on", []}
        ] do
      first = Map.put(base, elem(forbidden, 0), elem(forbidden, 1))

      assert {:error, {:invalid_child_keys, 0}} =
               FanoutPlan.compile(@request, [first, base])
    end
  end

  test "rejects blank, duplicate, undersized, oversized, and overlong children" do
    child = fn title, objective ->
      %{
        "title" => title,
        "objective" => objective,
        "expected_result" => "A useful result."
      }
    end

    assert {:error, :fanout_requires_at_least_two_children} =
             FanoutPlan.compile(@request, [child.("Only", "Only one")])

    assert {:error, {:invalid_child_field, 0, :title}} =
             FanoutPlan.compile(@request, [child.(" ", "one"), child.("two", "two")])

    assert {:error, {:duplicate_child, 1}} =
             FanoutPlan.compile(@request, [
               child.("One", "Same   objective"),
               child.("Two", " same objective ")
             ])

    assert {:error, {:duplicate_child, 1}} =
             FanoutPlan.compile(@request, [
               child.(" Same title ", "objective one"),
               child.("same TITLE", "objective two")
             ])

    assert {:error, {:too_many_children, 3, 2}} =
             FanoutPlan.compile(
               @request,
               [child.("one", "one"), child.("two", "two"), child.("three", "three")],
               max_children: 2
             )

    assert {:error, {:invalid_child_field, 0, :title}} =
             FanoutPlan.compile(@request, [
               child.(String.duplicate("x", 201), "one"),
               child.("two", "two")
             ])
  end

  test "rejects an absent request instead of manufacturing a binding" do
    children = [
      %{title: "one", objective: "one", expected_result: "one"},
      %{title: "two", objective: "two", expected_result: "two"}
    ]

    assert {:error, :invalid_original_request} = FanoutPlan.compile(" ", children)
    assert {:error, :invalid_original_request} = FanoutPlan.compile(nil, children)
  end

  test "canonical digest changes with normalized plan order or content" do
    children = [
      %{title: "one", objective: "research one", expected_result: "one result"},
      %{title: "two", objective: "research two", expected_result: "two results"}
    ]

    assert {:ok, first} = FanoutPlan.compile(@request, children)
    assert {:ok, same} = FanoutPlan.compile(@request, Enum.map(children, &Map.new/1))
    assert {:ok, reversed} = FanoutPlan.compile(@request, Enum.reverse(children))

    assert first.plan_sha256 == same.plan_sha256
    refute first.plan_sha256 == reversed.plan_sha256
  end

  test "request binding has one explicit 4,000-byte UTF-8 boundary" do
    child = fn suffix ->
      %{title: "task #{suffix}", objective: "do task #{suffix}", expected_result: "result"}
    end

    assert {:ok, _plan} =
             FanoutPlan.compile(String.duplicate("x", 4_000), [child.("one"), child.("two")])

    assert {:error, :original_request_too_large} =
             FanoutPlan.compile(String.duplicate("x", 4_001), [child.("one"), child.("two")])

    # 1,000 four-byte graphemes are accepted; the bound is bytes, not graphemes.
    assert {:ok, _plan} =
             FanoutPlan.compile(String.duplicate("🦉", 1_000), [child.("one"), child.("two")])

    assert {:error, :original_request_too_large} =
             FanoutPlan.compile(String.duplicate("🦉", 1_001), [child.("one"), child.("two")])
  end

  test "rejects expected results whose JSON encoding exceeds the durable field" do
    escaped = String.duplicate("\u0000", 500)

    assert {:error, {:encoded_acceptance_criteria_too_large, 0}} =
             FanoutPlan.compile(@request, [
               %{title: "one", objective: "one", expected_result: escaped},
               %{title: "two", objective: "two", expected_result: "result"}
             ])
  end

  test "overflow returns the complete normalized inert list only after validation" do
    children =
      for index <- 1..3 do
        %{
          title: " Task #{index} ",
          objective: " Do task #{index}. ",
          expected_result: " Result #{index}. "
        }
      end

    assert {:clarify,
            %{task_count: 3, max_children: 2, tasks: ["Do task 1.", "Do task 2.", "Do task 3."]}} =
             FanoutPlan.compile_admission(@request, children, max_children: 2)

    assert {:error, {:invalid_child_keys, 2}} =
             FanoutPlan.compile_admission(
               @request,
               List.update_at(children, 2, &Map.put(&1, :permission, :allowed)),
               max_children: 2
             )

    children =
      for index <- 1..17 do
        %{
          title: "task #{index}",
          objective: "do task #{index}",
          expected_result: "result #{index}"
        }
      end

    assert {:clarify, %{task_count: 17, max_children: 8, tasks: tasks}} =
             FanoutPlan.compile_admission(
               @request,
               children,
               max_children: 8
             )

    assert tasks == Enum.map(children, & &1.objective)
  end

  test "exact-counted compiler preserves task order without model-owned fields" do
    assert {:ok, plan} =
             FanoutPlan.compile_counted(
               "Do these two tasks in parallel: inspect alpha; inspect beta",
               ["inspect alpha", "inspect beta"],
               max_children: 8
             )

    assert plan.source == :exact_counted
    assert FanoutPlan.provenance(plan)["source"] == "counted_protocol"
    assert Enum.map(plan.children, & &1["objective"]) == ["inspect alpha", "inspect beta"]

    assert Enum.all?(plan.children, fn child ->
             Map.keys(child) |> Enum.sort() ==
               Enum.sort(["title", "objective", "expected_result"])
           end)

    assert {:error, {:duplicate_child, 1}} =
             FanoutPlan.compile_counted(@request, ["same", " SAME "])

    assert {:error, {:invalid_counted_task, 1}} =
             FanoutPlan.compile_counted(@request, ["valid", %{objective: "not text"}])
  end

  test "counted overflow is normalized and bounded before complete-list clarification" do
    assert {:clarify, %{task_count: 3, max_children: 2, tasks: ["one", "two", "three"]}} =
             FanoutPlan.compile_counted_admission(
               "Do these three tasks in parallel: one; two; three",
               ["one", "two", "three"],
               max_children: 2
             )

    assert {:error, {:duplicate_child, 1}} =
             FanoutPlan.compile_counted_admission(@request, ["same", " SAME ", "other"],
               max_children: 2
             )

    assert {:error, {:invalid_counted_task, 0}} =
             FanoutPlan.compile_counted_admission(
               "Do these three tasks in parallel: too long; two; three",
               [String.duplicate("x", 2_001), "two", "three"],
               max_children: 2
             )
  end
end
