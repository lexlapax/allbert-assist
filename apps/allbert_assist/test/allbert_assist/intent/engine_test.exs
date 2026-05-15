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
    assert annotated.trace_metadata.intent_candidates.total == 1
  end
end
