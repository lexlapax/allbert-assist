defmodule AllbertAssist.Workspace.PlanBuild.Panels.Preview do
  @moduledoc """
  Declarative Plan/Build preview panel node builder.

  This module produces Surface nodes only. Rendering and operator events stay
  in the web tier; workflow authority stays behind registered Plan-Build
  actions.
  """

  alias AllbertAssist.Surface.Node

  @registered_actions ~w[expand_workflow preview_plan start_plan_run]

  @spec node(map()) :: Node.t()
  def node(opts \\ %{}) when is_map(opts) do
    %Node{
      id: Map.get(opts, :id, "plan-build-preview"),
      component: :plan_preview_panel,
      props: %{
        title: Map.get(opts, :title, "Plan/Build Preview"),
        body: Map.get(opts, :body, "Review a workflow plan before it starts."),
        preview: Map.get(opts, :preview),
        workflow_id: Map.get(opts, :workflow_id),
        inputs: Map.get(opts, :inputs, %{}),
        registered_actions: @registered_actions
      }
    }
  end

  def registered_actions, do: @registered_actions
end
