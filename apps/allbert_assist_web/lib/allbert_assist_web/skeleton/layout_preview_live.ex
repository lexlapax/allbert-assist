defmodule AllbertAssistWeb.Skeleton.LayoutPreviewLive do
  @moduledoc """
  v0.61 M1 layout-system exploration preview screen.

  Renders the v0.60 walking-skeleton IA surfaces
  (`AllbertAssistWeb.Skeleton.PreviewLive.preview_surface/1`) under a per-system
  `data-layout-system` zone-composition delta, with the operator-chosen **Direction C**
  visual language (`data-visual-direction="c"`) applied, so the operator can preview
  each candidate layout system across all nine surfaces and choose one in M2.

  Disposable design-exploration behind the existing `:preview_routes` flag: reads no
  business state, exposes no effectful affordance, grants no authority, and is **not**
  the M3-M9 build. The catalog stays the rendering boundary; a layout system is a CSS
  zone-composition override applied through the shell, nothing more.
  """

  use AllbertAssistWeb, :live_view

  alias AllbertAssistWeb.Skeleton.LayoutSystemManifest
  alias AllbertAssistWeb.Skeleton.PreviewLive
  alias AllbertAssistWeb.Skeleton.RouteManifest
  alias AllbertAssistWeb.Workspace.Renderer, as: WorkspaceRenderer

  # The operator-chosen canonical visual language M1 renders every layout system in
  # (ADR 0079 / docs/design/visual-language-selected.md).
  @visual_direction "c"

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:preview_nav_items, RouteManifest.nav_items())
     |> assign(:visual_direction, @visual_direction)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    system = LayoutSystemManifest.fetch_system!(params["system"])
    surface = LayoutSystemManifest.fetch_surface!(params["surface"])
    route = RouteManifest.get!(surface)

    {:noreply,
     socket
     |> assign(:page_title, "Layout #{system}: #{route.title}")
     |> assign(:system, system)
     |> assign(:system_str, Atom.to_string(system))
     |> assign(:surface, surface)
     |> assign(:route, route)
     |> assign(:preview_surface, PreviewLive.preview_surface(route))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      content_width="full"
      visual_direction={@visual_direction}
      layout_system={@system_str}
    >
      <Layouts.operator_shell
        id="v061-layout-shell"
        active={@route.active_key}
        title={@route.title}
        subtitle={"v0.61 layout system #{@system_str} · Direction C · #{@surface}"}
        nav_items={@preview_nav_items}
        visual_direction={@visual_direction}
        layout_system={@system_str}
      >
        <section
          id={"v061-layout-#{@system_str}-#{@surface}"}
          class="operator-panel-stack"
          data-skeleton-preview="v060"
          data-layout-preview="v061"
          data-layout-system={@system_str}
          data-visual-direction={@visual_direction}
          data-layout-surface={@surface}
          data-skeleton-route={@route.route_id}
          data-skeleton-live-data="false"
          data-authority="none"
          data-settings-keys="0"
          data-keyboard-focus-ready="true"
          data-high-contrast-ready="true"
          data-reduced-motion-ready="true"
          data-catalog-components={catalog_components(@route)}
          aria-labelledby={"v061-layout-title-#{@system_str}-#{@surface}"}
        >
          <div class="operator-panel">
            <div class="operator-panel-header">
              <div>
                <h2 id={"v061-layout-title-#{@system_str}-#{@surface}"}>{@route.title}</h2>
                <p>
                  Layout system {@system_str} composition of the {@route.nav_group} / {@route.active_key} surface, in Direction C. Placeholder-only, no live data.
                </p>
              </div>
              <span class="workspace-status-pill workspace-status-neutral">
                v0.61 layout {@system_str}
              </span>
            </div>

            <.live_component
              module={WorkspaceRenderer}
              id={"v061-layout-surface-#{@system_str}-#{@surface}"}
              surface={@preview_surface}
              renderer_context={%{}}
              workspace_state={%{}}
            />
          </div>

          <p class="sr-only">
            layout-rendering status=pass system={@system_str} surface={@surface} visual_direction={@visual_direction} live_data=false authority=none
          </p>
        </section>
      </Layouts.operator_shell>
    </Layouts.app>
    """
  end

  defp catalog_components(route),
    do: Enum.map_join(route.catalog_components, ",", &Atom.to_string/1)
end
