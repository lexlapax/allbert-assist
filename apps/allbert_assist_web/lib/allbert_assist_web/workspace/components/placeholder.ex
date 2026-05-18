defmodule AllbertAssistWeb.Workspace.Components.Placeholder do
  @moduledoc """
  Fallback renderer for workspace component atoms outside the catalog.
  """

  use AllbertAssistWeb, :live_component

  @impl true
  def update(assigns, socket) do
    {:ok, assign(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"workspace-placeholder-#{@node.id}"}
      class="rounded border border-dashed border-base-300 bg-base-100 p-3 text-sm text-base-content/70"
      data-placeholder-component={@node.component}
    >
      <span class="font-mono">{component_name(@node.component)}</span>
      <span> unknown workspace component</span>
    </div>
    """
  end

  defp component_name(component) when is_atom(component), do: Atom.to_string(component)
  defp component_name(component), do: to_string(component)
end
