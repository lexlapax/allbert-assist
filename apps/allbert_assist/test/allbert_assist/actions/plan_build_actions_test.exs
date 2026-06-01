defmodule AllbertAssist.Actions.PlanBuildActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Confirmations
  alias AllbertAssist.Confirmations.ResourceMetadata
  alias AllbertAssist.Objectives
  alias AllbertAssist.Runtime.Redactor

  setup do
    original_home = System.get_env("ALLBERT_HOME")
    original_paths_config = Application.get_env(:allbert_assist, AllbertAssist.Paths)

    home =
      Path.join(System.tmp_dir!(), "allbert-plan-actions-#{System.unique_integer([:positive])}")

    System.put_env("ALLBERT_HOME", home)
    Application.put_env(:allbert_assist, AllbertAssist.Paths, home: home)
    File.mkdir_p!(Path.join(home, "workflows"))
    copy_fixture!("multi_step", home)

    on_exit(fn ->
      restore_env("ALLBERT_HOME", original_home)
      restore_app_env(AllbertAssist.Paths, original_paths_config)
      File.rm_rf!(home)
    end)

    {:ok, home: home, context: %{actor: "local", user_id: "local", channel: :cli}}
  end

  test "list, inspect, expand, and preview run through Actions.Runner", %{context: context} do
    assert {:ok, %{status: :completed} = listed} = Runner.run("list_workflows", %{}, context)
    assert [%{id: "multi_step"}] = listed.output_data.workflows

    assert {:ok, %{status: :completed}} =
             Runner.run("inspect_workflow", %{workflow_id: "multi_step"}, context)

    assert {:ok, %{status: :completed} = expanded} =
             Runner.run(
               "expand_workflow",
               %{workflow_id: "multi_step", inputs: %{since: "today"}},
               context
             )

    assert expanded.output_data.step_count == 3

    assert {:ok, %{status: :advisory} = previewed} =
             Runner.run(
               "preview_plan",
               %{workflow_id: "multi_step", inputs: %{since: "today"}},
               context
             )

    assert previewed.output_data.preview.workflow_id == "multi_step"
  end

  test "preview_plan synthesizes advisory plan text without workflow YAML", %{context: context} do
    assert {:ok, %{status: :advisory} = previewed} =
             Runner.run(
               "preview_plan",
               %{plan_text: "plan: collect issues and summarize them"},
               context
             )

    assert previewed.output_data.preview.workflow_id == "ad_hoc_plan"
    assert previewed.output_data.preview.step_count == 2
  end

  test "start_plan_run requires approval and approval creates objective", %{context: context} do
    assert {:ok, pending} =
             Runner.run(
               "start_plan_run",
               %{workflow_id: "multi_step", inputs: %{since: "today"}},
               context
             )

    assert pending.status == :needs_confirmation
    assert is_binary(pending.confirmation_id)
    assert pending.output_data.preview.workflow_id == "multi_step"

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "test approval"},
               context
             )

    assert approved.status == :completed
    assert is_binary(get_in(approved, [:output_data, :objective_id]))
    assert get_in(approved, [:output_data, :step_count]) == 3
  end

  test "start_plan_run confirmation renders plan resource metadata", %{context: context} do
    assert {:ok, pending} =
             Runner.run(
               "start_plan_run",
               %{workflow_id: "multi_step", inputs: %{since: "today"}},
               context
             )

    assert {:ok, confirmation} = Confirmations.read(pending.confirmation_id)

    assert ResourceMetadata.lines(confirmation) == [
             "Plan workflow: multi_step",
             "Plan steps: 3",
             "Plan authority gates: 1"
           ]
  end

  test "cancel_plan_run cancels workflow objective and records durable reason", %{
    context: context
  } do
    assert {:ok, pending} =
             Runner.run(
               "start_plan_run",
               %{workflow_id: "multi_step", inputs: %{since: "today"}},
               context
             )

    assert {:ok, approved} =
             Runner.run(
               "approve_confirmation",
               %{id: pending.confirmation_id, reason: "test approval"},
               context
             )

    objective_id = get_in(approved, [:output_data, :objective_id])

    assert {:ok, %{status: :cancelled} = cancelled} =
             Runner.run(
               "cancel_plan_run",
               %{objective_id: objective_id, reason: "operator changed plan"},
               context
             )

    assert cancelled.output_data.cancelled?
    assert {:ok, objective} = Objectives.get_objective(objective_id)
    assert objective.status == "cancelled"

    assert Enum.any?(
             Objectives.list_events(objective_id),
             &(&1.kind == "cancelled" and &1.summary =~ "operator changed plan")
           )
  end

  test "plan previews redact secret-shaped inputs and params", %{context: context} do
    assert Redactor.redact("token=Bearer raw-secret") == "token=Bearer [REDACTED]"

    assert {:ok, %{status: :advisory} = previewed} =
             Runner.run(
               "preview_plan",
               %{plan_text: "plan: use sk-abcdef123456 and token=Bearer raw-secret"},
               context
             )

    preview = inspect(previewed.output_data.preview)
    refute preview =~ "sk-abcdef123456"
    refute preview =~ "raw-secret"
    assert preview =~ "[REDACTED]"
  end

  test "preview_plan rejects editor overrides for unknown step ids", %{context: context} do
    assert {:ok, %{status: :error} = previewed} =
             Runner.run(
               "preview_plan",
               %{
                 workflow_id: "multi_step",
                 edits: %{"steps" => %{"unknown" => %{"enabled" => "true"}}}
               },
               context
             )

    assert previewed.output_data.error.reason == :unknown_step_override
  end

  defp copy_fixture!(id, home) do
    File.cp!(
      Path.expand("../../fixtures/v0.44/workflows/#{id}.yaml", __DIR__),
      Path.join([home, "workflows", "#{id}.yaml"])
    )
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_app_env(module, nil), do: Application.delete_env(:allbert_assist, module)
  defp restore_app_env(module, value), do: Application.put_env(:allbert_assist, module, value)
end
