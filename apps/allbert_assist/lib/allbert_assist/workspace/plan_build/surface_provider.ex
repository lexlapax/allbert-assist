defmodule AllbertAssist.Workspace.PlanBuild.SurfaceProvider do
  @moduledoc """
  Core Plan/Build workspace panel provider.

  The provider contributes declarative panel metadata only. Component catalog
  membership and rendering do not grant authority; all mutations still flow
  through registered Plan-Build actions.
  """

  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.PlanBuild.Panels.{Preview, RunProgress}

  def surfaces, do: [preview_surface(), run_progress_surface()]

  def surface_catalog do
    [
      %{component: :plan_preview_panel, allowed_props: [], allowed_bindings: []},
      %{component: :plan_run_progress_panel, allowed_props: [], allowed_bindings: []}
    ]
  end

  def preview_surface do
    panel_surface(:plan_build_preview_panel, "Plan/Build", :canvas_panels, 15, [
      panel_node(
        "plan-build-preview-shell",
        "Plan/Build",
        "Preview and approve workflow plans.",
        [
          Preview.node()
        ]
      )
    ])
  end

  def run_progress_surface do
    panel_surface(:plan_build_run_progress_panel, "Plan Runs", :canvas_panels, 16, [
      panel_node("plan-build-run-shell", "Plan Runs", "Track workflow-backed objective runs.", [
        RunProgress.node()
      ])
    ])
  end

  defp panel_surface(id, label, zone, order, nodes) do
    %Surface{
      id: id,
      app_id: :allbert,
      label: label,
      path: "/workspace",
      kind: :panel,
      zone: zone,
      status: :available,
      nodes: nodes,
      fallback_text: "#{label} is available in the workspace.",
      metadata: %{visible_when: :always, order: order}
    }
  end

  defp panel_node(id, title, body, children) do
    %Node{
      id: id,
      component: :panel,
      props: %{title: title, body: body},
      children: children
    }
  end
end
