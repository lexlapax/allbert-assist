defmodule AllbertAssistWeb.Workspace.Components.Base do
  @moduledoc """
  Shared renderer template for simple workspace catalog components.
  """

  use Phoenix.Component

  defmacro __using__(opts) do
    component = Keyword.fetch!(opts, :component)
    title = Keyword.get(opts, :title, titleize(component))
    description = Keyword.get(opts, :description, default_description(component))
    stub? = Keyword.get(opts, :stub?, false)

    quote bind_quoted: [
            component: component,
            title: title,
            description: description,
            stub?: stub?
          ] do
      @moduledoc "Workspace renderer for the `#{inspect(component)}` catalog component."

      use AllbertAssistWeb, :live_component

      alias AllbertAssistWeb.Workspace.Components.Base

      @workspace_component component
      @workspace_title title
      @workspace_description description
      @workspace_stub? stub?

      @impl true
      def update(assigns, socket) do
        {:ok, Base.assign_defaults(socket, assigns)}
      end

      @impl true
      def render(assigns) do
        assigns =
          assign(assigns,
            component: @workspace_component,
            component_title: @workspace_title,
            component_description: @workspace_description,
            stub?: @workspace_stub?
          )

        Base.render_simple(assigns)
      end
    end
  end

  def render_simple(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class={component_class(@component, @stub?)}
      data-workspace-component={@component}
      data-workspace-renderer="component"
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 class="text-sm font-semibold leading-6">
            {title(@node, @component_title)}
          </h2>
          <p class="text-xs text-base-content/60">
            {summary(@node, @component_description)}
          </p>
        </div>
        <span :if={@stub?} class="badge badge-outline shrink-0">stub</span>
      </div>
      <p :if={metric(@component, @renderer_context)} class="mt-2 text-xs text-base-content/60">
        {metric(@component, @renderer_context)}
      </p>
    </section>
    """
  end

  def assign_defaults(socket, assigns) do
    Phoenix.Component.assign(socket, assigns)
    |> Phoenix.Component.assign_new(:renderer_context, fn -> %{} end)
    |> Phoenix.Component.assign_new(:workspace_state, fn -> %{} end)
  end

  def component_class(_component, true) do
    "rounded border border-dashed border-base-300 bg-base-100 p-3 text-sm"
  end

  def component_class(_component, false) do
    "rounded border border-base-300 bg-base-100 p-3 text-sm"
  end

  def title(node, fallback), do: prop(node, :title, prop(node, :label, fallback))

  def summary(node, fallback) do
    prop(node, :body, prop(node, :text, prop(node, :subtitle, prop(node, :value, fallback))))
  end

  def metric(:canvas, context), do: count_metric(context, :canvas_tiles, "tile")

  def metric(:ephemeral_surface, context),
    do: count_metric(context, :ephemeral_surfaces, "surface")

  def metric(:badge_strip, context), do: count_metric(context, :active_objectives, "objective")
  def metric(_component, _context), do: nil

  def prop(%{props: props}, key, fallback) when is_map(props) do
    Map.get(props, key) || Map.get(props, Atom.to_string(key)) || fallback
  end

  def prop(_node, _key, fallback), do: fallback

  defp count_metric(context, key, label) do
    count =
      context
      |> Map.get(key, [])
      |> length()

    "#{count} #{pluralize(label, count)}"
  end

  defp pluralize(label, 1), do: label
  defp pluralize(label, _count), do: "#{label}s"

  defp titleize(component) do
    component
    |> Atom.to_string()
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp default_description(component), do: "#{titleize(component)} renderer"
end
