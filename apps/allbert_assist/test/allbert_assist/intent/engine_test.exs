defmodule AllbertAssist.Intent.EngineTest do
  use ExUnit.Case, async: true

  alias AllbertAssist.Intent.Decision
  alias AllbertAssist.Intent.Engine
  alias AllbertAssist.Intent.EvalFixtures

  test "decide returns the v0.11 decision shape for a direct-answer turn" do
    assert {:ok, decision} = Engine.decide(EvalFixtures.request(text: "what can you do?"))

    assert %Decision{} = decision
    assert decision.intent == :direct_answer
    assert decision.selected_action == "direct_answer"
    assert decision.trace_metadata.intent_candidates.selected.kind == :action
    assert decision.trace_metadata.intent_candidates.selected.id == "direct_answer"
    assert decision.trace_metadata.intent_candidates.total > 1
  end

  test "put_candidate_metadata annotates existing decisions without changing selected action" do
    assert {:ok, decision} =
             Decision.new(%{
               intent: :list_skills,
               selected_action: "list_skills",
               selected_skill: "list-skills",
               context: %{request: EvalFixtures.request()}
             })

    annotated = Engine.put_candidate_metadata(decision)

    assert annotated.selected_action == "list_skills"
    assert annotated.trace_metadata.intent_candidates.selected.id == "list_skills"
    assert annotated.trace_metadata.intent_candidates.total > 1
  end

  test "collects registry-driven action skill and surface candidates" do
    candidates = Engine.collect_candidates(EvalFixtures.request())

    assert Enum.any?(candidates, &match?(%{kind: :action, action_name: "direct_answer"}, &1))
    assert Enum.any?(candidates, &match?(%{kind: :skill, skill_name: "direct-answer"}, &1))
    assert Enum.any?(candidates, &match?(%{kind: :surface, app_id: :allbert}, &1))
    assert length(candidates) <= 80
  end

  test "candidate metadata includes rejected registry candidates" do
    assert {:ok, decision} =
             Decision.new(%{
               intent: :list_skills,
               selected_action: "list_skills",
               selected_skill: "list-skills",
               context: %{request: EvalFixtures.request()}
             })

    annotated = Engine.put_candidate_metadata(decision, %{request: EvalFixtures.request()})

    assert %{rejected: rejected} = annotated.trace_metadata.intent_candidates
    assert Enum.any?(rejected, &(&1.kind == :action and &1.id == "direct_answer"))
  end

  test "decide returns inert surface navigation when a registered surface matches" do
    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: "Open Allbert chat for me"))

    assert decision.intent == :open_surface
    assert decision.selected_action == nil
    assert decision.selected_skill == nil
    assert decision.trace_metadata.surface_target.path == "/agent"
    assert decision.trace_metadata.intent_candidates.selected.kind == :surface
    assert decision.trace_metadata.intent_candidates.selected.surface_id == "agent"
  end

  test "unknown active app falls back to allbert without creating atoms" do
    unknown = "__allbert_unknown_app_#{System.unique_integer([:positive])}__"

    assert {:ok, decision} =
             Engine.decide(EvalFixtures.request(text: "what can you do?", active_app: unknown))

    assert decision.active_app == :allbert
    assert %{kind: :unknown_app_id, fallback: :allbert} = hd(decision.diagnostics)

    assert_raise ArgumentError, fn ->
      String.to_existing_atom(unknown)
    end
  end
end
