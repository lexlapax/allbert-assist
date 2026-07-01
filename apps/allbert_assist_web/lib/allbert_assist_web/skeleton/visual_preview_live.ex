defmodule AllbertAssistWeb.Skeleton.VisualPreviewLive do
  @moduledoc """
  v0.60b M3/M6 styled-variant preview screen.

  Renders the exact v0.60 walking-skeleton hero compositions
  (`AllbertAssistWeb.Skeleton.PreviewLive.preview_surface/1`) under a per-direction
  `data-visual-direction` token/theme delta, so the operator can evaluate ≥3 divergent
  visual directions (and, for M6, the selected proof) as real pixels.

  This is disposable design-exploration behind the existing `:preview_routes` flag: it
  reads no business state, exposes no effectful affordance, grants no authority, and is
  **not** the v0.61 build. The catalog stays the rendering boundary; each direction is a
  token override applied through the shell, nothing more.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssistWeb.Skeleton.PreviewLive
  alias AllbertAssistWeb.Skeleton.RouteManifest
  alias AllbertAssistWeb.Skeleton.VisualDirectionManifest
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :preview_nav_items, RouteManifest.nav_items())}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    requested = VisualDirectionManifest.fetch_direction!(params["direction"])
    screen = VisualDirectionManifest.fetch_screen!(params["screen"])
    route = RouteManifest.get!(screen)

    # `:selected` (the M6 proof) renders as the operator's M5-chosen direction so the
    # proof shows the chosen language, not a fourth one.
    render_direction = VisualDirectionManifest.render_direction(requested)

    {:noreply,
     socket
     |> assign(:page_title, "Visual #{requested}: #{route.title}")
     |> assign(:requested, requested)
     |> assign(:requested_str, Atom.to_string(requested))
     |> assign(:direction, render_direction)
     |> assign(:direction_str, Atom.to_string(render_direction))
     |> assign(:selected_proof?, requested == VisualDirectionManifest.selected_direction())
     |> assign(:screen, screen)
     |> assign(:route, route)
     |> assign(:surface, PreviewLive.preview_surface(route))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} content_width="full" visual_direction={@direction_str}>
      <Layouts.operator_shell
        id="v060b-visual-shell"
        active={@route.active_key}
        title={@route.title}
        subtitle={shell_subtitle(@selected_proof?, @requested_str, @direction_str, @screen)}
        nav_items={@preview_nav_items}
        visual_direction={@direction_str}
      >
        <section
          id={"v060b-visual-#{@requested_str}-#{@screen}"}
          class="operator-panel-stack"
          data-skeleton-preview="v060"
          data-visual-preview="v060b"
          data-visual-requested={@requested_str}
          data-visual-direction={@direction_str}
          data-selected-proof={to_string(@selected_proof?)}
          data-visual-screen={@screen}
          data-skeleton-route={@route.route_id}
          data-skeleton-live-data="false"
          data-authority="none"
          data-settings-keys="0"
          data-keyboard-focus-ready="true"
          data-high-contrast-ready="true"
          data-reduced-motion-ready="true"
          data-catalog-components={catalog_components(@route)}
          aria-labelledby={"v060b-visual-title-#{@requested_str}-#{@screen}"}
        >
          <div class="operator-panel">
            <div class="operator-panel-header">
              <div>
                <h2 id={"v060b-visual-title-#{@requested_str}-#{@screen}"}>{@route.title}</h2>
                <p>
                  {if @selected_proof?, do: "Selected proof", else: "Direction #{@requested_str}"} styled variant
                  of the {@route.nav_group} / {@route.active_key} hero screen, rendered as direction {@direction_str}. Placeholder-only, no live data.
                </p>
              </div>
              <span class="workspace-status-pill workspace-status-neutral">
                {if @selected_proof?,
                  do: "v0.60b selected proof",
                  else: "v0.60b direction #{@requested_str}"}
              </span>
            </div>

            <.live_component
              module={WorkspaceRenderer}
              id={"v060b-visual-surface-#{@requested_str}-#{@screen}"}
              surface={@surface}
              renderer_context={%{}}
              workspace_state={%{}}
            />
          </div>

          <p class="sr-only">
            hero-rendering status=pass direction={@direction_str} screen={@screen} live_data=false authority=none
          </p>
        </section>
      </Layouts.operator_shell>
    </Layouts.app>
    """
  end

  defp catalog_components(route),
    do: Enum.map_join(route.catalog_components, ",", &Atom.to_string/1)

  defp shell_subtitle(true, _requested, direction, screen),
    do: "v0.60b selected-direction proof (#{direction}) — #{screen}"

  defp shell_subtitle(false, requested, _direction, screen),
    do: "v0.60b visual direction #{requested} — #{screen}"
end
