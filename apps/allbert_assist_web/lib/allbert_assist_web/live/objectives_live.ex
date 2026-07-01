defmodule AllbertAssistWeb.ObjectivesLive do
  @moduledoc """
  Objectives index — the durable-work surface's navigable route.

  v0.61 M4 adds the explicit `/objectives` index route (paired with the existing
  `/objectives/:id` detail route) as the one non-landing route the IA/navigation
  overhaul introduces, so Objectives has a stable navigation frame in the D sidebar
  shell. M10.1 completes the content pane with the local user's real objectives list
  through the catalog renderer; this remains presentation-only and grants no
  authority.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.Objective
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

  @user_id "local"

  @impl true
  def mount(params, _session, socket) do
    user_id = params |> Map.get("user", @user_id) |> blank_to_default(@user_id)
    objectives = Objectives.list_objectives(user_id, limit: 50)

    {:ok,
     assign(socket,
       user_id: user_id,
       objectives: objectives,
       objectives_surface: objectives_surface(objectives)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} content_width="full">
      <Layouts.operator_shell
        active="objectives"
        title="Objectives"
        subtitle="Durable goals, steps, and resumable work"
        labelledby="objectives-page-title"
      >
        <Patterns.elevated_card id="objectives-index" title="Objectives">
          <.live_component
            module={WorkspaceRenderer}
            id="objectives-catalog-renderer"
            surface={@objectives_surface}
            renderer_context={%{user_id: @user_id, page: :objectives_index}}
            workspace_state={%{}}
          />

          <div :if={@objectives != []} id="objectives-index-links" class="operator-catalog-actions">
            <.link
              :for={objective <- @objectives}
              id={"objective-open-#{objective.id}"}
              navigate={~p"/objectives/#{objective.id}"}
              class={Patterns.button_class!("secondary")}
            >
              Open {objective.title}
            </.link>
          </div>

          <div :if={@objectives == []} id="objectives-empty-actions" class="operator-catalog-actions">
            <.link navigate={~p"/workspace"} class={Patterns.button_class!("secondary")}>
              Go to workspace
            </.link>
          </div>
        </Patterns.elevated_card>
      </Layouts.operator_shell>
    </Layouts.app>
    """
  end

  defp objectives_surface(objectives) do
    %Surface{
      id: "objectives-page",
      app_id: :allbert,
      label: "Objectives",
      kind: :workspace,
      status: :available,
      nodes: objective_nodes(objectives)
    }
  end

  defp objective_nodes([]) do
    [
      %Node{
        id: "objectives-empty",
        component: :empty_state,
        props: %{
          title: "No objectives yet.",
          body: "Durable goals appear here after a workspace conversation frames resumable work."
        }
      }
    ]
  end

  defp objective_nodes(objectives) do
    Enum.map(objectives, &objective_card_node/1)
  end

  defp objective_card_node(%Objective{} = objective) do
    %Node{
      id: "objective-index-#{objective.id}",
      component: :objective_card,
      props: %{
        dom_id: "objective-index-#{objective.id}",
        title: objective.title,
        body: objective_body(objective),
        status: objective.status,
        external_id: objective.id
      }
    }
  end

  defp objective_body(%Objective{} = objective) do
    [
      "goal=#{objective.objective}",
      "app=#{objective.active_app || "allbert"}",
      "step=#{objective.current_step_id || "none"}",
      "thread=#{objective.source_thread_id || "none"}"
    ]
    |> Enum.join(" | ")
  end

  defp blank_to_default(value, default) when is_binary(value) do
    if String.trim(value) == "", do: default, else: value
  end

  defp blank_to_default(_value, default), do: default
end
