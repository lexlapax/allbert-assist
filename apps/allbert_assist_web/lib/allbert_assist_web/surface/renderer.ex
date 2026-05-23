defmodule AllbertAssistWeb.Surface.Renderer do
  @moduledoc """
  Shared Phoenix renderer for validated Allbert Surface nodes.

  Renderer dispatch comes from `AllbertAssist.Surface.Catalog`; this module
  only executes the already-registered descriptor.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Surface.Catalog
  alias AllbertAssist.Surface.Node

  @impl true
  def update(assigns, socket) do
    node = Map.get(assigns, :node, unknown_node())

    {:ok,
     socket
     |> assign(assigns)
     |> assign(:node, node)
     |> assign(:component_id, component_id(assigns, node))
     |> assign_renderer(renderer_descriptor(node))
     |> assign_new(:renderer_context, fn -> %{} end)
     |> assign_new(:workspace_state, fn -> %{} end)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"surface-renderer-#{@component_id}"}
      data-surface-renderer-node={@node.id}
      data-surface-renderer-component={@node.component}
    >
      <.live_component
        :if={@renderer_kind == :live_component}
        module={@component_module}
        id={@component_id}
        node={@node}
        renderer_context={@renderer_context}
        workspace_state={@workspace_state}
      />
      <%= if @renderer_kind == :function_component do %>
        {render_function_component(@component_module, @component_function, assigns)}
      <% end %>
    </div>
    """
  end

  defp render_function_component(module, function, assigns) do
    apply(module, function, [assigns])
  end

  defp assign_renderer(socket, {:live_component, module}) do
    socket
    |> assign(:renderer_kind, :live_component)
    |> assign(:component_module, module)
    |> assign(:component_function, nil)
  end

  defp assign_renderer(socket, {:function_component, module, function}) do
    socket
    |> assign(:renderer_kind, :function_component)
    |> assign(:component_module, module)
    |> assign(:component_function, function)
  end

  defp renderer_descriptor(%Node{component: component}), do: Catalog.renderer_for(component)
  defp renderer_descriptor(_node), do: Catalog.renderer_for(:unknown)

  defp unknown_node do
    %Node{id: "unknown", component: :unknown, props: %{component: "unknown"}}
  end

  defp component_id(%{id: id}, _node) when is_binary(id) and id != "", do: id

  defp component_id(_assigns, %Node{id: node_id}), do: "surface-component-#{node_id}"
end
