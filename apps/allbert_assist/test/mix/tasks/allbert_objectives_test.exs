defmodule Mix.Tasks.Allbert.ObjectivesTest do
  use AllbertAssist.DataCase, async: false

  import ExUnit.CaptureIO

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Fanout
  alias AllbertAssist.TestSupport.FanoutReportFixture
  alias AllbertAssist.TestSupport.ReadyEffectContext
  alias Mix.Tasks.Allbert.Objectives, as: ObjectivesTask

  setup do
    previous_halt = Application.get_env(:allbert_assist, Mix.Tasks.Allbert.Objectives)

    Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Objectives,
      halt_fun: fn code -> throw({:halt, code}) end
    )

    on_exit(fn ->
      Mix.Task.reenable("allbert.objectives")

      if previous_halt do
        Application.put_env(:allbert_assist, Mix.Tasks.Allbert.Objectives, previous_halt)
      else
        Application.delete_env(:allbert_assist, Mix.Tasks.Allbert.Objectives)
      end
    end)
  end

  test "lists and shows objectives through registered actions" do
    assert {:ok, objective} =
             Objectives.create_objective(
               %{
                 user_id: "alice",
                 title: "Analyze AAPL",
                 objective: "Complete one analysis for AAPL.",
                 active_app: "stocksage"
               },
               ReadyEffectContext.context()
             )

    assert {:ok, _step} =
             Objectives.create_step(
               %{
                 objective_id: objective.id,
                 kind: "action",
                 status: "proposed",
                 stage: "propose_steps",
                 candidate_action: "StockSage.Actions.RunAnalysis",
                 action_params: %{ticker: "AAPL"}
               },
               ReadyEffectContext.context()
             )

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
             Objectives.create_objective(
               %{
                 user_id: "alice",
                 title: "Cancel AAPL",
                 objective: "Stop the analysis.",
                 status: "running"
               },
               ReadyEffectContext.context()
             )

    assert {:halt, 64} =
             catch_throw(
               capture_io(:stderr, fn ->
                 ObjectivesTask.run(["cancel", objective.id, "--user", "alice"])
               end)
             )

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

  test "show renders the authoritative fan-out phase, outcome, delivery, and child results" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 title: "CLI fan-in",
                 objective: "Render the joined tree"
               }),
               ["one", "two"]
             )

    Enum.each(children, fn child ->
      FanoutReportFixture.complete_child!(child, "result #{child.queue_position}")
    end)

    selected_body = select_report!(parent.id, "deterministic_fallback")

    output =
      capture_io(fn ->
        assert :ok = ObjectivesTask.run(["show", parent.id, "--user", "alice"])
      end)

    assert output =~ "Fan-out phase: joined"
    assert output =~ "Join outcome: success"
    assert output =~ "Report composition: fallback"
    assert output =~ "Report source: deterministic_fallback"
    assert output =~ "Report delivery: pending"
    assert output =~ "Report: #{selected_body}"
    assert output =~ "- completed one — result 0"
    assert output =~ "- completed two — result 1"
  end

  test "show maps a model-selected report to completed without changing its body" do
    assert {:ok, %{parent: parent, children: children}} =
             Fanout.frame(
               ReadyEffectContext.attach(%{
                 user_id: "alice",
                 title: "Model CLI fan-in",
                 objective: "Render one model report"
               }),
               ["one", "two"]
             )

    Enum.each(children, fn child ->
      FanoutReportFixture.complete_child!(child, "result #{child.queue_position}")
    end)

    selected_body = select_report!(parent.id, "model")

    output =
      capture_io(fn ->
        assert :ok = ObjectivesTask.run(["show", parent.id, "--user", "alice"])
      end)

    assert output =~ "Fan-out phase: joined"
    assert output =~ "Report composition: completed"
    assert output =~ "Report source: model"
    assert output =~ "Report: #{selected_body}"
  end

  test "operator alias must match user" do
    assert {:halt, 66} =
             catch_throw(
               capture_io(:stderr, fn ->
                 ObjectivesTask.run(["list", "--user", "alice", "--operator", "bob"])
               end)
             )
  end

  test "show exits with documented not-found code" do
    assert {:halt, 65} =
             catch_throw(
               capture_io(:stderr, fn ->
                 ObjectivesTask.run(["show", "obj_missing", "--user", "alice"])
               end)
             )
  end

  test "continue terminal advisory is a successful command" do
    assert {:ok, objective} =
             Objectives.create_objective(
               %{
                 user_id: "alice",
                 title: "Already abandoned",
                 objective: "No more work.",
                 status: "abandoned"
               },
               ReadyEffectContext.context()
             )

    output =
      capture_io(fn ->
        assert :ok = ObjectivesTask.run(["continue", objective.id, "--user", "alice"])
      end)

    assert output =~ "cannot continue"
    assert output =~ "Reason: Objective is abandoned."
  end

  # v1.3 M9.b.12.b. This hand-rolled its own sections, body and provenance,
  # pinning `layout_version: 1`, so selection failed
  # `:fanout_report_layout_generation_mismatch` once layout v2 landed. The shared
  # fixture builds all three through the production seams.
  defp select_report!(parent_id, "deterministic_fallback"),
    do: FanoutReportFixture.select_pending!(parent_id, :fallback).report_body

  defp select_report!(parent_id, "model"),
    do: FanoutReportFixture.select_pending!(parent_id, :model).report_body
end
