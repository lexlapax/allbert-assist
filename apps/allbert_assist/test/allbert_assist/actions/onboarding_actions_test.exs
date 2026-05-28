defmodule AllbertAssist.Actions.OnboardingActionsTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Actions.Onboarding.StepComplete
  alias AllbertAssist.Onboarding

  test "onboarding_step_complete records objective progress" do
    assert {:ok, state} = Onboarding.frame_or_resume("alice")

    assert {:ok, response} =
             StepComplete.run(
               %{
                 user_id: "alice",
                 objective_id: state.objective.id,
                 step_id: state.current_step.id,
                 outcome: "completed"
               },
               %{}
             )

    assert response.status == :completed
    assert response.completed_step.status == "completed"
    assert response.current_step.key == "pick_provider_profile"
    assert [%{name: "onboarding_step_complete", status: :completed}] = response.actions
  end
end
