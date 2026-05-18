defmodule AllbertAssistWeb.Workspace.Renderer do
  @moduledoc """
  Dispatches declarative workspace Surface nodes to web components.

  The core catalog stays web-agnostic. M4 wires the dispatcher and keeps most
  components on a placeholder renderer; later milestones replace those
  placeholders with concrete component modules.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssist.Workspace.Catalog
  alias AllbertAssistWeb.Workspace.Components.Chat
  alias AllbertAssistWeb.Workspace.Components.Placeholder

  @type renderer_module :: Chat | Placeholder

  @spec renderer_for(atom()) :: renderer_module()
  def renderer_for(:chat), do: Chat

  def renderer_for(component) when is_atom(component) do
    case Catalog.component_renderer(component) do
      {:ok, :placeholder} -> Placeholder
      {:error, :unknown_component} -> Placeholder
    end
  end

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
      class="workspace-renderer space-y-4"
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
      class="workspace-node space-y-4"
      data-workspace-component={@node.component}
      data-workspace-node={@node.id}
    >
      <.live_component
        module={renderer_for(@node.component)}
        id={node_component_id(@id, @node)}
        node={@node}
        renderer_context={@renderer_context}
        workspace_state={@workspace_state}
      />

      <div :if={@node.children != []} class="workspace-node-children space-y-4">
        <.live_component
          :for={child <- @node.children}
          module={__MODULE__}
          id={node_renderer_id(@id, child)}
          node={child}
          renderer_context={@renderer_context}
          workspace_state={@workspace_state}
        />
      </div>
    </div>
    """
  end

  defp node_renderer_id(parent_id, %Node{id: node_id}), do: "#{parent_id}:#{node_id}:renderer"
  defp node_component_id(parent_id, %Node{id: node_id}), do: "#{parent_id}:#{node_id}:component"
end
