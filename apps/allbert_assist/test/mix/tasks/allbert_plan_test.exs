defmodule Mix.Tasks.Allbert.PlanTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Objectives
  alias Mix.Tasks.Allbert.Plan, as: PlanTask

  setup do
    on_exit(fn -> Mix.Task.reenable("allbert.plan") end)
    :ok
  end

  test "lists, shows, and cancels plan runs through registered actions" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "local",
               title: "Workflow run",
               objective: "Run workflow.",
               status: "running",
               active_app: "allbert",
               source_intent: "workflow:multi_step:1"
             })

    assert {:ok, _step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "proposed",
               stage: "propose_steps",
               provider: "plan_build",
               candidate_action: "direct_answer"
             })

    list_output =
      capture_io(fn ->
        assert :ok = PlanTask.run(["list"])
      end)

    assert list_output =~ objective.id
    assert list_output =~ "workflow:multi_step:1"

    Mix.Task.reenable("allbert.plan")

    ids_output =
      capture_io(fn ->
        assert :ok = PlanTask.run(["list", "--format", "ids"])
      end)

    assert ids_output =~ objective.id

    Mix.Task.reenable("allbert.plan")

    show_output =
      capture_io(fn ->
        assert :ok = PlanTask.run(["show", objective.id])
      end)

    assert show_output =~ "Plan: #{objective.id}"
    assert show_output =~ "Steps: 1"

    Mix.Task.reenable("allbert.plan")

    cancel_output =
      capture_io(fn ->
        assert :ok = PlanTask.run(["cancel", objective.id, "--reason", "operator stopped it"])
      end)

    assert cancel_output =~ "Objective #{objective.id} cancelled: operator stopped it"
  end
end
