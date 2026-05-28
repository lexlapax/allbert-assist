defmodule AllbertAssist.OnboardingTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Onboarding

  test "frames one resumable onboarding objective with planned steps" do
    assert {:ok, state} = Onboarding.frame_or_resume("alice")

    assert state.created? == true
    assert state.objective.title == "First-run onboarding"
    assert state.objective.source_intent == Onboarding.source_intent()
    assert state.objective.status == "running"
    assert length(state.steps) == 9
    assert state.current_step.key == "welcome_scope"
    assert state.current_step.evidence =~ "Active model profile: local"
    assert state.current_step.next_command == "mix allbert.onboard complete welcome_scope"
    assert state.evidence.active_model_profile == "local"
    assert Enum.map(state.steps, & &1.index) == Enum.to_list(1..9)

    channel_step = Enum.find(state.steps, &(&1.key == "optional_channel_registration"))
    assert channel_step.evidence =~ "credentials="
    assert channel_step.evidence =~ "missing"
    refute channel_step.evidence =~ "%{"

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

    assert {:ok, channel_state} = Onboarding.frame_or_resume("bob")

    selected_optional =
      Enum.find(channel_state.steps, &(&1.key == "optional_channel_registration"))

    assert {:ok, selected} =
             Onboarding.complete_step("bob", channel_state.objective.id, selected_optional.id, %{
               outcome: "selected"
             })

    assert selected.completed_step.status == "selected"
    assert selected.objective.progress_summary =~ "0/9"

    events = Objectives.list_events(state.objective.id, limit: 10)
    assert Enum.any?(events, &(&1.kind == "step_completed"))
    channel_events = Objectives.list_events(channel_state.objective.id, limit: 10)
    assert Enum.any?(channel_events, &(&1.kind == "step_selected"))
  end
end
