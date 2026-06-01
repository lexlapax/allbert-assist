defmodule AllbertAssist.Workspace.PlanBuildPanelsTest do
  use ExUnit.Case, async: false

  alias AllbertAssist.Actions.Registry
  alias AllbertAssist.Surface
  alias AllbertAssist.Workspace.PlanBuild.Panels.{Preview, RunProgress}
  alias AllbertAssist.Workspace.PlanBuild.SurfaceProvider

  test "Plan/Build provider contributes valid panel surfaces" do
    assert [preview, run_progress] = SurfaceProvider.surfaces()

    assert {:ok, ^preview} = Surface.validate_surface(preview)
    assert {:ok, ^run_progress} = Surface.validate_surface(run_progress)

    assert preview.zone == :canvas_panels
    assert run_progress.zone == :canvas_panels
    assert preview.metadata.order < run_progress.metadata.order
  end

  test "panel nodes advertise only registered Plan-Build actions" do
    for action <- Preview.registered_actions() ++ RunProgress.registered_actions() do
      assert {:ok, capability} = Registry.capability(action)
      assert capability.module |> inspect() |> String.contains?("PlanBuild")
    end
  end
end
