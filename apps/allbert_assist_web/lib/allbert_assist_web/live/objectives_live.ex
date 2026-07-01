defmodule AllbertAssistWeb.ObjectivesLive do
  @moduledoc """
  Objectives index — the durable-work surface's navigable route.

  v0.61 M4 adds the explicit `/objectives` index route (paired with the existing
  `/objectives/:id` detail route) as the one non-landing route the IA/navigation
  overhaul introduces, so Objectives has a stable navigation frame in the D sidebar
  shell. M5 recomposes the content pane with the real objectives list; this is the
  presentation-only nav frame, reading no live data and granting no authority.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssistWeb.Workspace.Components.Patterns

  @user_id "local"

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, user_id: @user_id)}
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
          <p>
            Durable goals appear here. Start one from a workspace conversation, or open
            an in-flight objective from its detail view to inspect its steps, acceptance,
            and resumable work.
          </p>
          <p>
            <.link navigate={~p"/workspace"} class={Patterns.button_class!("secondary")}>
              Go to workspace
            </.link>
          </p>
        </Patterns.elevated_card>
      </Layouts.operator_shell>
    </Layouts.app>
    """
  end
end
