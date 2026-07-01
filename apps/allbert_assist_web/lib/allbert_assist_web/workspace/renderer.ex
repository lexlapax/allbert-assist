defmodule AllbertAssistWeb.Workspace.Renderer do
  @moduledoc """
  Dispatches declarative workspace Surface nodes to web components.

  The core catalog stays web-agnostic. The web renderer owns only visual
  dispatch, layout wrappers, and client-side shell affordances.

  v0.31 M7 moves component dispatch behind `AllbertAssist.Surface.Catalog`.
  This module owns the workspace wrappers, child recursion, and shell
  affordances around the shared node renderer.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Catalog, as: SurfaceCatalog
  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Surface.Renderer, as: SurfaceRenderer
  alias AllbertAssistWeb.Workspace.Components.Placeholder

  def renderer_for(component) when is_atom(component) do
    case SurfaceCatalog.renderer_for(component) do
      {:live_component, module} -> module
      {:function_component, module, function} -> {module, function}
    end
  end

  def renderer_for(_component), do: Placeholder

  def renderer_descriptor_for(component), do: SurfaceCatalog.renderer_for(component)

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:renderer_context, fn -> %{} end)
     |> assign_new(:workspace_state, fn -> %{} end)}
  end

  @impl true
  def render(%{surface: %Surface{}} = assigns) do
    ~H"""
    <div
      id={@id}
      class="workspace-renderer"
      data-workspace-renderer="surface"
      data-workspace-surface={@surface.id}
    >
      <.live_component
        :for={node <- @surface.nodes}
        module={__MODULE__}
        id={node_renderer_id(@id, node)}
        node={node}
        renderer_context={@renderer_context}
        workspace_state={@workspace_state}
      />
    </div>
    """
  end

  def render(%{node: %Node{}} = assigns) do
    ~H"""
    <div
      id={"workspace-node-#{@node.id}"}
      class={["workspace-node", node_class(@node)]}
      data-workspace-component={@node.component}
      data-workspace-node={@node.id}
      role={node_role(@node)}
      aria-labelledby={node_labelledby(@node)}
      aria-modal={node_aria_modal(@node)}
      phx-hook={node_hook(@node)}
      phx-click-away={node_dismiss_event(@node)}
      phx-window-keydown={node_dismiss_event(@node)}
      phx-key={node_dismiss_key(@node)}
      phx-value-surface-id={node_surface_id(@node)}
      data-skeleton-composition-route={skeleton_prop(@node, :skeleton_composition_route)}
      data-skeleton-composition-zone={skeleton_prop(@node, :skeleton_composition_zone)}
      data-skeleton-composition-component={skeleton_prop(@node, :skeleton_composition_component)}
    >
      <.live_component
        module={SurfaceRenderer}
        id={node_component_id(@id, @node)}
        node={@node}
        renderer_context={@renderer_context}
        workspace_state={@workspace_state}
      />

      <div :if={@node.children != []} class={children_class(@node)}>
        <%= for child <- @node.children do %>
          <.live_component
            module={__MODULE__}
            id={node_renderer_id(@id, child)}
            node={child}
            renderer_context={@renderer_context}
            workspace_state={@workspace_state}
          />
          <div
            :if={workspace_split_after?(@node, child)}
            id="workspace-split-resizer"
            class="workspace-split-resizer"
            role="separator"
            tabindex="0"
            aria-label="Resize chat and canvas panes"
            aria-orientation="vertical"
            aria-valuemin="35"
            aria-valuemax="70"
            aria-valuenow="55"
            aria-controls="workspace-node-workspace-chat workspace-node-workspace-canvas-region"
            data-default-value="55"
            phx-hook="WorkspaceSplitResizer"
          >
            <span aria-hidden="true" />
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp node_renderer_id(parent_id, %Node{id: node_id}), do: "#{parent_id}:#{node_id}:renderer"
  defp node_component_id(parent_id, %Node{id: node_id}), do: "#{parent_id}:#{node_id}:component"

  defp node_class(%Node{component: :workspace}), do: "workspace-root-node"
  defp node_class(%Node{component: :workspace_shell}), do: "workspace-root-node"
  defp node_class(%Node{component: :chat}), do: "workspace-chat-node"
  defp node_class(%Node{component: :canvas}), do: "workspace-canvas-node"
  defp node_class(%Node{component: :nav_rail}), do: "workspace-nav-rail-node"
  defp node_class(%Node{component: :utility_drawer}), do: "workspace-utility-drawer-node"

  defp node_class(%Node{component: :ephemeral_surface, children: []}),
    do: "workspace-ephemeral-node-empty"

  defp node_class(%Node{component: :ephemeral_surface}), do: "workspace-ephemeral-node"
  defp node_class(%Node{component: :badge_strip, children: []}), do: "workspace-badges-node-empty"
  defp node_class(%Node{component: :badge_strip}), do: "workspace-badges-node"
  defp node_class(%Node{component: :tile}), do: "workspace-tile-node"
  defp node_class(%Node{component: :tabs}), do: "workspace-tabs-node"
  defp node_class(_node), do: nil

  defp children_class(%Node{component: :workspace}),
    do: "workspace-node-children workspace-root-grid"

  defp children_class(%Node{component: :workspace_shell}),
    do: "workspace-node-children workspace-root-grid"

  defp children_class(%Node{component: :nav_rail}),
    do: "workspace-node-children workspace-rail-stack"

  defp children_class(%Node{component: :canvas}),
    do: "workspace-node-children workspace-canvas-tiles"

  defp children_class(%Node{component: :ephemeral_surface}),
    do: "workspace-node-children workspace-ephemeral-content"

  defp children_class(%Node{component: :badge_strip}),
    do: "workspace-node-children workspace-badge-row"

  defp children_class(%Node{component: :job_card}),
    do: "workspace-node-children workspace-action-row"

  defp children_class(%Node{component: :tabs}),
    do: "workspace-node-children workspace-tabs-children"

  defp children_class(_node), do: "workspace-node-children workspace-stack"

  defp workspace_split_after?(%Node{component: :workspace}, %Node{component: :chat}), do: true

  defp workspace_split_after?(%Node{component: :workspace_shell}, %Node{component: :chat}),
    do: true

  defp workspace_split_after?(_parent, _child), do: false

  defp node_role(%Node{component: :tile}), do: "article"

  defp node_role(%Node{component: :ephemeral_surface, children: children}) when children != [],
    do: "dialog"

  defp node_role(%Node{component: :tabs}), do: "tablist"

  defp node_role(%Node{component: :nav_rail}), do: "navigation"
  defp node_role(%Node{component: :utility_drawer}), do: "complementary"

  defp node_role(%Node{component: component}) when component in [:canvas, :badge_strip],
    do: "region"

  defp node_role(_node), do: nil

  defp node_labelledby(%Node{component: component} = node)
       when component in [:tile, :ephemeral_surface, :canvas, :badge_strip] do
    component_title_id(node)
  end

  defp node_labelledby(_node), do: nil

  defp node_aria_modal(%Node{component: :ephemeral_surface, children: children})
       when children != [],
       do: "true"

  defp node_aria_modal(_node), do: nil

  defp node_hook(%Node{component: :ephemeral_surface, children: children}) when children != [] do
    "FocusTrap"
  end

  defp node_hook(%Node{component: :tabs}), do: "WorkspaceTabs"
  defp node_hook(_node), do: nil

  defp node_dismiss_event(%Node{} = node) do
    if dismissible_ephemeral?(node), do: "dismiss_workspace_ephemeral"
  end

  defp node_dismiss_key(%Node{} = node) do
    if dismissible_ephemeral?(node), do: "escape"
  end

  defp node_surface_id(%Node{} = node) do
    if dismissible_ephemeral?(node), do: prop(node, :surface_id)
  end

  defp dismissible_ephemeral?(%Node{component: :ephemeral_surface, children: children} = node)
       when children != [] do
    prop(node, :dismissible?, true) != false and is_binary(prop(node, :surface_id))
  end

  defp dismissible_ephemeral?(_node), do: false

  defp prop(node, key, fallback \\ nil)

  defp prop(%Node{props: props}, key, fallback) when is_map(props) do
    case Map.fetch(props, key) do
      {:ok, value} -> value
      :error -> Map.get(props, Atom.to_string(key), fallback)
    end
  end

  defp prop(_node, _key, fallback), do: fallback

  defp skeleton_prop(%Node{} = node, key) do
    if prop(node, :skeleton_preview?, false) == true do
      prop(node, key)
    end
  end

  defp component_title_id(%Node{id: node_id}), do: "workspace-component-title-#{node_id}"
end
