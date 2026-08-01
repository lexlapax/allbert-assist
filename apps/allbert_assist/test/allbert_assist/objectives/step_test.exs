defmodule AllbertAssist.Objectives.StepTest do
  use AllbertAssist.DataCase, async: false

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Step

  setup do
    {:ok, objective} =
      Objectives.create_objective(%{
        user_id: "alice",
        title: "Analyze AAPL",
        objective: "Complete one analysis for AAPL."
      })

    %{objective: objective}
  end

  test "changeset accepts valid action and delegate steps", %{objective: objective} do
    for attrs <- [
          %{
            id: Objectives.new_id("step"),
            objective_id: objective.id,
            kind: "action",
            status: "proposed",
            stage: "propose_steps",
            candidate_action: "StockSage.Actions.RunAnalysis",
            action_params: Jason.encode!(%{ticker: "AAPL"})
          },
          %{
            id: Objectives.new_id("step"),
            objective_id: objective.id,
            kind: "delegate_agent",
            status: "proposed",
            stage: "propose_steps",
            delegate_agent_id: "stocksage.native_worker"
          }
        ] do
      assert %Ecto.Changeset{valid?: true} = Step.changeset(%Step{}, attrs)
    end
  end

  test "changeset rejects malformed enum values and oversized payload", %{objective: objective} do
    changeset =
      Step.changeset(%Step{}, %{
        id: Objectives.new_id("step"),
        objective_id: objective.id,
        kind: "shell",
        status: "paused",
        stage: "future_stage",
        action_params: String.duplicate("x", 2_001)
      })

    refute changeset.valid?
    assert %{kind: [_], status: [_], stage: [_], action_params: [_]} = errors_on(changeset)
  end

  test "step transitions keep the same row id", %{objective: objective} do
    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               stage: "propose_steps"
             })

    assert {:ok, selected} =
             Objectives.transition_step(step, :selected, %{stage: :authorize_step})

    assert {:ok, running} =
             Objectives.transition_step(selected, :running, %{stage: :execute_step})

    assert {:ok, completed} =
             Objectives.transition_step(running, :completed, %{
               stage: :execute_step,
               result_summary: "completed"
             })

    assert completed.id == step.id
    assert completed.status == "completed"
    assert completed.result_summary == "completed"
  end

  test "a confirmation resume binding is valid SHA-256 and write-once", %{objective: objective} do
    digest = String.duplicate("a", 64)

    assert {:ok, step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               stage: "authorize_step",
               confirmation_resume_params_sha256: digest
             })

    assert {:ok, unchanged} =
             Objectives.update_step(step, %{confirmation_resume_params_sha256: digest})

    assert unchanged.confirmation_resume_params_sha256 == digest

    assert {:error, replacement} =
             Objectives.update_step(step, %{
               confirmation_resume_params_sha256: String.duplicate("b", 64)
             })

    assert %{confirmation_resume_params_sha256: [_]} = errors_on(replacement)

    invalid =
      Step.changeset(%Step{}, %{
        id: Objectives.new_id("step"),
        objective_id: objective.id,
        kind: "action",
        stage: "authorize_step",
        confirmation_resume_params_sha256: "not-a-digest"
      })

    refute invalid.valid?
    assert %{confirmation_resume_params_sha256: [_]} = errors_on(invalid)
  end
end
