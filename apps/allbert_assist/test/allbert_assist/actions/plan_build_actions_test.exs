defmodule AllbertAssist.Actions.PlanBuildActionsTest do
  use AllbertAssist.DataCase, async: false
  @moduletag :external_runtime_serial

  alias AllbertAssist.Actions.Runner

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
