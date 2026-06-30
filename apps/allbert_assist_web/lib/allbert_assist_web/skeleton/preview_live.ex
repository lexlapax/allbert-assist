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
        route_composition_node(route),
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
    node(route, component, title, body, %{}, [])
  end

  defp node(route, component, title, body, props, children) do
    default_node_id = "v060-#{route.route_id}-#{component}"
    {node_id, props} = Map.pop(props, :node_id, default_node_id)
    default_dom_id = default_dom_id(route, component, node_id, default_node_id)

    %Node{
      id: node_id,
      component: component,
      props:
        Map.merge(
          %{
            title: title,
            body: body,
            status: "neutral",
            tone: "neutral",
            dom_id: default_dom_id
          },
          props
        ),
      children: children
    }
  end

  defp default_dom_id(route, component, default_node_id, default_node_id),
    do: "v060-component-#{route.route_id}-#{component}"

  defp default_dom_id(_route, _component, node_id, _default_node_id),
    do: "v060-component-#{node_id}"

  defp route_composition_node(%{route_id: :launch} = route) do
    composition_zone(
      route,
      :button,
      "Launch action zone",
      "Declared launch action is rendered as a disabled preview placeholder.",
      [
        component_node(route, :button, "Launch placeholder", "No action is wired in v0.60.",
          disabled?: true,
          variant: "secondary"
        )
      ]
    )
  end

  defp route_composition_node(%{route_id: :onboarding} = route) do
    composition_zone(
      route,
      :onboarding_panel,
      "Onboarding wizard zone",
      "Represents the QuickStart / Advanced wizard shell without loading onboarding state.",
      [
        placeholder_component_node(
          route,
          :models_panel,
          "Model path placeholder",
          "No model doctor or provider setup is run in the v0.60 preview.",
          node_id: "v060-onboarding-models_panel"
        ),
        component_node(
          route,
          :status_badge,
          "Review checkpoint placeholder",
          "Persona and settings seeds remain pending explicit review.",
          node_id: "v060-onboarding-review-status"
        )
      ]
    )
  end

  defp route_composition_node(%{route_id: :workspace} = route) do
    composition_zone(
      route,
      :chat,
      "Chat-primary workspace zone",
      "Represents chat, timeline, and composer structure without runtime conversation state.",
      [
        component_node(route, :timeline, "Timeline placeholder", "Runtime turns stay empty."),
        component_node(route, :composer, "Composer placeholder", "Prompt entry stays inert.")
      ]
    )
  end

  defp route_composition_node(%{route_id: :objectives} = route) do
    composition_zone(
      route,
      :objective_card,
      "Objectives composition zone",
      "Represents durable objective summaries without reading objective state.",
      [
        component_node(
          route,
          :objective_card,
          "Objective placeholder",
          "No objective is loaded in the v0.60 preview."
        )
      ]
    )
  end

  defp route_composition_node(%{route_id: :jobs} = route) do
    composition_zone(
      route,
      :job_card,
      "Jobs composition zone",
      "Represents job cards and scan-friendly run history without scheduler reads.",
      [
        component_node(
          route,
          :job_card,
          "Job placeholder",
          "No job is loaded in the v0.60 preview."
        ),
        component_node(route, :table, "Run history placeholder", "Rows appear in v0.61+.")
      ]
    )
  end

  defp route_composition_node(%{route_id: :models} = route) do
    composition_zone(
      route,
      :models_panel,
      "Model readiness zone",
      "Represents the model readiness panel without running provider doctors.",
      [
        component_node(
          route,
          :settings_card,
          "Model policy placeholder",
          "Settings Central remains the downstream authority."
        )
      ]
    )
  end

  defp route_composition_node(%{route_id: :channels} = route) do
    composition_zone(
      route,
      :channel_card,
      "Channel setup zone",
      "Represents configured / unconfigured channel cards without opening adapters.",
      [
        component_node(
          route,
          :channel_card,
          "Channel placeholder",
          "No channel is configured here."
        )
      ]
    )
  end

  defp route_composition_node(%{route_id: :settings} = route) do
    composition_zone(
      route,
      :settings_panel,
      "Settings and policy zone",
      "Represents Settings Central, surface policy, and intents without reading settings.",
      [
        placeholder_component_node(
          route,
          :surface_policy_panel,
          "Surface policy placeholder",
          "No grants or policy records are loaded in the v0.60 preview.",
          node_id: "v060-settings-surface_policy_panel"
        ),
        placeholder_component_node(
          route,
          :intents_panel,
          "Intent routing placeholder",
          "No intent descriptors or routing state are loaded in the v0.60 preview.",
          node_id: "v060-settings-intents_panel"
        )
      ]
    )
  end

  defp route_composition_node(%{route_id: :trust} = route) do
    composition_zone(
      route,
      :trace_viewer,
      "Trust evidence zone",
      "Represents traces and confirmations without loading audits or pending approvals.",
      [
        component_node(
          route,
          :trace_viewer,
          "Trace placeholder",
          "No trace is loaded in the v0.60 preview."
        ),
        component_node(
          route,
          :confirmation_card,
          "Confirmation placeholder",
          "No confirmation is pending in the v0.60 preview."
        )
      ]
    )
  end

  defp composition_zone(route, target_component, title, body, children) do
    props =
      route
      |> composition_props(target_component)
      |> Map.put(:node_id, "v060-#{route.route_id}-composition-zone")

    node(route, :section, title, body, props, children)
  end

  defp component_node(route, component, title, body, props \\ []) do
    node(
      route,
      component,
      title,
      body,
      Map.merge(composition_props(route, component), Map.new(props)),
      []
    )
  end

  defp placeholder_component_node(route, target_component, title, body, props) do
    node(
      route,
      :section,
      title,
      body,
      Map.merge(composition_props(route, target_component), Map.new(props)),
      []
    )
  end

  defp composition_props(route, component) do
    %{
      skeleton_composition_route: Atom.to_string(route.route_id),
      skeleton_composition_zone: route.active_key,
      skeleton_composition_component: Atom.to_string(component)
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
