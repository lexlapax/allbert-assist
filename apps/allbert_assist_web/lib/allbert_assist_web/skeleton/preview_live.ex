defmodule AllbertAssistWeb.Skeleton.PreviewLive do
  @moduledoc """
  Placeholder-only v0.60 walking skeleton screen.

  These previews prove route, nav, shell, and catalog rendering for the M2 IA.
  They intentionally read no business state and expose no effectful affordances.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Skeleton.RouteManifest
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :preview_nav_items, RouteManifest.nav_items())}
  end

  @impl true
  def handle_params(_params, _uri, socket) do
    route = RouteManifest.get!(socket.assigns.live_action)

    {:noreply,
     socket
     |> assign(:page_title, "Preview: #{route.title}")
     |> assign(:route, route)
     |> assign(:surface, preview_surface(route))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} content_width="full">
      <Layouts.operator_shell
        id="v060-preview-shell"
        active={@route.active_key}
        title={@route.title}
        subtitle="v0.60 IA walking skeleton preview"
        nav_items={@preview_nav_items}
      >
        <section
          id={"v060-preview-#{@route.route_id}"}
          class="operator-panel-stack"
          data-skeleton-preview="v060"
          data-skeleton-route={@route.route_id}
          data-skeleton-live-data="false"
          data-authority="none"
          data-settings-keys="0"
          data-keyboard-focus-ready="true"
          data-high-contrast-ready="true"
          data-reduced-motion-ready="true"
          data-catalog-components={catalog_components(@route)}
          aria-labelledby={"v060-preview-title-#{@route.route_id}"}
        >
          <div class="operator-panel">
            <div class="operator-panel-header">
              <div>
                <h2 id={"v060-preview-title-#{@route.route_id}"}>{@route.title}</h2>
                <p>
                  Placeholder-only screen for {@route.nav_group} / {@route.active_key}.
                </p>
              </div>
              <span class="workspace-status-pill workspace-status-neutral">
                v0.60 preview
              </span>
            </div>

            <.live_component
              module={WorkspaceRenderer}
              id={"v060-preview-surface-#{@route.route_id}"}
              surface={@surface}
              renderer_context={%{}}
              workspace_state={%{}}
            />
          </div>

          <div class="operator-panel">
            <div class="operator-panel-header">
              <div>
                <h3>Catalog atoms</h3>
                <p>Known component atoms from the M2 preview-route manifest.</p>
              </div>
            </div>
            <ul class="workspace-chip-list" aria-label="Catalog atoms used by this preview">
              <li
                :for={component <- @route.catalog_components}
                class="allbert-chip"
                data-skeleton-catalog-component={component}
              >
                {component}
              </li>
            </ul>
          </div>

          <p class="sr-only">
            walking-skeleton-routes-resolve-001 status=pass route={@route.preview_path}
          </p>
        </section>
      </Layouts.operator_shell>
    </Layouts.app>
    """
  end

  defp preview_surface(route) do
    %Surface{
      id: :"v060_preview_#{route.route_id}",
      app_id: :allbert,
      label: route.title,
      path: route.preview_path,
      kind: :route,
      status: :placeholder,
      fallback_text: "#{route.title} preview",
      metadata: %{v060_preview?: true, live_data?: false, authority: :none},
      nodes: [
        node(route, :section, "Screen purpose", purpose(route)),
        node(route, :empty_state, "#{route.title} placeholder", placeholder_copy(route)),
        node(
          route,
          :status_badge,
          "Authority",
          "Preview only: no live data, no settings writes, no effectful action."
        ),
        node(route, :list, "Downstream handoff", handoff(route))
      ]
    }
  end

  defp node(route, component, title, body) do
    %Node{
      id: "v060-#{route.route_id}-#{component}",
      component: component,
      props: %{
        title: title,
        body: body,
        status: "neutral",
        tone: "neutral",
        dom_id: "v060-component-#{route.route_id}-#{component}"
      },
      children: []
    }
  end

  defp purpose(%{route_id: :launch}), do: "Start, resume, or route into onboarding."

  defp purpose(%{route_id: :onboarding}),
    do: "Guide QuickStart or Advanced setup toward first useful chat."

  defp purpose(%{route_id: :workspace}), do: "Make chat the primary work surface."
  defp purpose(%{route_id: :objectives}), do: "Inspect durable objectives and resumable work."
  defp purpose(%{route_id: :jobs}), do: "Inspect scheduled and background activity."
  defp purpose(%{route_id: :models}), do: "Show model/provider readiness and repair paths."
  defp purpose(%{route_id: :channels}), do: "Connect external surfaces after setup."
  defp purpose(%{route_id: :settings}), do: "Review operator-tunable settings and policy."
  defp purpose(%{route_id: :trust}), do: "Inspect confirmation, trace, and audit posture."

  defp placeholder_copy(route) do
    "#{route.title} is intentionally static in v0.60. v0.61 fills this screen with real presentation."
  end

  defp handoff(%{route_id: route_id}) when route_id in [:launch, :workspace],
    do: "v0.61 presentation overhaul owns the real screen."

  defp handoff(%{route_id: :onboarding}), do: "v0.63 guided onboarding owns the real wizard."

  defp handoff(%{route_id: :models}),
    do: "v0.62 model setup hooks and v0.63 onboarding consume this screen."

  defp handoff(%{route_id: :channels}), do: "Channel setup remains explicit and policy-bounded."
  defp handoff(%{route_id: :settings}), do: "Settings Central remains the settings authority."
  defp handoff(%{route_id: :trust}), do: "Security Central remains the authority boundary."
  defp handoff(_route), do: "v0.61 fills in the production composition."

  defp catalog_components(route),
    do: Enum.map_join(route.catalog_components, ",", &Atom.to_string/1)
end
