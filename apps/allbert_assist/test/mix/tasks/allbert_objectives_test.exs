defmodule Mix.Tasks.Allbert.ObjectivesTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Objectives
  alias Mix.Tasks.Allbert.Objectives, as: ObjectivesTask

  setup do
    on_exit(fn -> Mix.Task.reenable("allbert.objectives") end)
  end

  test "lists and shows objectives through registered actions" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Analyze AAPL",
               objective: "Complete one analysis for AAPL.",
               active_app: "stocksage"
             })

    assert {:ok, _step} =
             Objectives.create_step(%{
               objective_id: objective.id,
               kind: "action",
               status: "proposed",
               stage: "propose_steps",
               candidate_action: "StockSage.Actions.RunAnalysis",
               action_params: %{ticker: "AAPL"}
             })

    list_output =
      capture_io(fn ->
        assert :ok = ObjectivesTask.run(["list", "--user", "alice"])
      end)

    assert list_output =~ objective.id
    assert list_output =~ "Analyze AAPL"

    Mix.Task.reenable("allbert.objectives")

    show_output =
      capture_io(fn ->
        assert :ok = ObjectivesTask.run(["show", objective.id, "--user", "alice"])
      end)

    assert show_output =~ "Objective: #{objective.id}"
    assert show_output =~ "StockSage.Actions.RunAnalysis"
  end

  test "cancel requires reason and cancels through registered action" do
    assert {:ok, objective} =
             Objectives.create_objective(%{
               user_id: "alice",
               title: "Cancel AAPL",
               objective: "Stop the analysis.",
               status: "running"
             })

    assert_raise Mix.Error, ~r/Usage error \(64\): cancel requires --reason/, fn ->
      capture_io(fn ->
        ObjectivesTask.run(["cancel", objective.id, "--user", "alice"])
      end)
    end

    Mix.Task.reenable("allbert.objectives")

    output =
      capture_io(fn ->
        assert :ok =
                 ObjectivesTask.run([
                   "cancel",
                   objective.id,
                   "--user",
                   "alice",
                   "--reason",
                   "not needed"
                 ])
      end)

    assert output =~ "Objective #{objective.id} cancelled: not needed"

    assert {:ok, cancelled} = Objectives.get_objective(objective.id)
    assert cancelled.status == "cancelled"
  end

  test "operator alias must match user" do
    assert_raise Mix.Error, ~r/--user and --operator must match/, fn ->
      capture_io(fn ->
        ObjectivesTask.run(["list", "--user", "alice", "--operator", "bob"])
      end)
    end
  end
end
