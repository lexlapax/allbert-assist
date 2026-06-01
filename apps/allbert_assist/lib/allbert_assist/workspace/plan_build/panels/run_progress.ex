defmodule AllbertAssist.Workspace.PlanBuild.Panels.RunProgress do
  @moduledoc """
  Declarative Plan/Build run-progress panel node builder.
  """

  alias AllbertAssist.Surface.Node

  @registered_actions ~w[cancel_plan_run list_plan_runs]

  @spec node(map()) :: Node.t()
  def node(opts \\ %{}) when is_map(opts) do
    %Node{
      id: Map.get(opts, :id, "plan-build-run-progress"),
      component: :plan_run_progress_panel,
      props: %{
        title: Map.get(opts, :title, "Run Progress"),
        body: Map.get(opts, :body, "Track workflow-backed objective steps."),
        objective: Map.get(opts, :objective),
        steps: Map.get(opts, :steps, []),
        events: Map.get(opts, :events, []),
        registered_actions: @registered_actions
      }
    }
  end

  def registered_actions, do: @registered_actions
end
