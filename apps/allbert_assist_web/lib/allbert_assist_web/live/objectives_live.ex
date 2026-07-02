defmodule AllbertAssistWeb.ObjectivesLive do
  @moduledoc """
  Objectives index — the durable-work surface's navigable route.

  v0.61 M4 adds the explicit `/objectives` index route (paired with the existing
  `/objectives/:id` detail route) as the one non-landing route the IA/navigation
  overhaul introduces, so Objectives has a stable navigation frame in the D sidebar
  shell. M10.1 completes the content pane with the local operator's real objectives
  list through the catalog renderer.

  v0.61 M10.2 reads that list through the registered `list_objectives` action with a
  server-derived `"local"` identity (PermissionGate-gated, redacted `objective_map`
  projection) rather than a direct store read with a URL-controllable user id. The
  index reads the operator's own objectives through the ADR-0073 read-through-action
  boundary and grants no authority.
  """

  use AllbertAssistWeb, :live_view

  on_mount {AllbertAssistWeb.Live.SharedShellHooks, :shell_chrome}

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssistWeb.Workspace.Components.Patterns
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

  @user_id "local"

  @impl true
  def mount(_params, _session, socket) do
    objectives = list_objectives(@user_id)

    {:ok,
     assign(socket,
       user_id: @user_id,
       page_title: "Objectives",
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
        theme={@workspace_theme}
        overflow_open?={@workspace_overflow_open?}
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
              Open {Map.get(objective, :title, "objective")}
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

  # Reads the operator's own objectives through the registered read-only action
  # (server-derived identity precedence + PermissionGate), never a URL-supplied user.
  defp list_objectives(user_id) do
    case Runner.run(
           "list_objectives",
           %{user_id: user_id, limit: 50},
           ContextBuilder.live_view_context(%{user_id: user_id},
             surface: "AllbertAssistWeb.ObjectivesLive"
           )
         ) do
      {:ok, %{status: :completed, objectives: objectives}} -> objectives
      _other -> []
    end
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

  defp objective_card_node(objective) do
    %Node{
      id: "objective-index-#{objective.id}",
      component: :objective_card,
      props: %{
        dom_id: "objective-index-#{objective.id}",
        title: Map.get(objective, :title, "Objective"),
        body: objective_body(objective),
        status: Map.get(objective, :status),
        external_id: objective.id
      }
    }
  end

  defp objective_body(objective) do
    [
      "goal=#{Map.get(objective, :objective, "")}",
      "app=#{Map.get(objective, :active_app, "allbert")}",
      "step=#{Map.get(objective, :current_step_id, "none")}",
      "thread=#{Map.get(objective, :source_thread_id, "none")}"
    ]
    |> Enum.join(" | ")
  end
end
