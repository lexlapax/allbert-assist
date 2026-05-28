defmodule AllbertAssist.OnboardingTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Onboarding
  alias AllbertAssist.Objectives

  test "frames one resumable onboarding objective with planned steps" do
    assert {:ok, state} = Onboarding.frame_or_resume("alice")

    assert state.created? == true
    assert state.objective.title == "First-run onboarding"
    assert state.objective.source_intent == Onboarding.source_intent()
    assert state.objective.status == "running"
    assert length(state.steps) == 9
    assert state.current_step.key == "welcome_scope"
    assert Enum.map(state.steps, & &1.index) == Enum.to_list(1..9)

    assert {:ok, resumed} = Onboarding.frame_or_resume("alice")

    assert resumed.created? == false
    assert resumed.objective.id == state.objective.id
    assert resumed.current_step.id == state.current_step.id
  end

  test "records completed and skipped onboarding progress" do
    assert {:ok, state} = Onboarding.frame_or_resume("alice")
    first = state.current_step

    assert {:ok, advanced} =
             Onboarding.complete_step("alice", state.objective.id, first.id, %{
               outcome: "completed",
               note: "scope accepted"
             })

    assert advanced.completed_step.status == "completed"
    assert advanced.current_step.key == "pick_provider_profile"
    assert advanced.objective.progress_summary =~ "1/9"

    optional =
      Enum.find(advanced.steps, &(&1.key == "optional_channel_registration"))

    assert {:ok, skipped} =
             Onboarding.complete_step("alice", state.objective.id, optional.id, %{
               outcome: "skipped"
             })

    assert skipped.completed_step.status == "skipped"

    events = Objectives.list_events(state.objective.id, limit: 10)
    assert Enum.any?(events, &(&1.kind == "step_completed"))
  end
end
