defmodule AllbertAssistWeb.Workspace.Components.Base do
  @moduledoc """
  Shared renderer template for simple workspace catalog components.
  """

  use Phoenix.Component

  import AllbertAssistWeb.CoreComponents, only: [icon: 1]

  alias AllbertAssist.Surface.Catalog

  defmacro __using__(opts) do
    component = Keyword.fetch!(opts, :component)
    title = Keyword.get(opts, :title, titleize(component))
    description = Keyword.get(opts, :description, default_description(component))
    stub? = Keyword.get(opts, :stub?, false)
    custom? = Keyword.get(opts, :custom?, false)

    quote bind_quoted: [
            component: component,
            title: title,
            description: description,
            stub?: stub?,
            custom?: custom?
          ] do
      @moduledoc "Workspace renderer for the `#{inspect(component)}` catalog component."

      use AllbertAssistWeb, :live_component

      alias AllbertAssistWeb.Workspace.Components.Base

      @workspace_component component
      @workspace_title title
      @workspace_description description
      @workspace_stub? stub?

      unless custom? do
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
  end

  def render_simple(assigns) do
    ~H"""
    <article
      id={dom_id(@node)}
      class={component_class(@component, @stub?)}
      data-workspace-component={@component}
      data-workspace-renderer="component"
      data-status={card_status(@node)}
      aria-labelledby={component_title_id(@node)}
    >
      <header class="workspace-card-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name={component_icon(@component)} class="size-4" />
        </span>
        <div class="min-w-0 flex-1">
          <h2 id={component_title_id(@node)} class="workspace-card-title">
            {title(@node, @component_title)}
          </h2>
          <p :if={present?(summary(@node, @component_description))} class="workspace-card-summary">
            {summary(@node, @component_description)}
          </p>
        </div>
        <span
          :if={present?(card_status(@node))}
          class={["workspace-status-pill", status_class(card_status(@node))]}
        >
          {humanize_status(card_status(@node))}
        </span>
        <span :if={@stub?} class="workspace-status-pill workspace-status-neutral">
          v0.26 stub
        </span>
      </header>

      <footer class="workspace-card-footer">
        <span :if={metric(@component, @renderer_context)}>
          {metric(@component, @renderer_context)}
        </span>
        <span
          :if={present?(card_external_id(@node))}
          class="workspace-mono workspace-copy-target workspace-card-id"
          id={"workspace-card-id-#{@node.id}"}
          phx-hook="CopyToClipboard"
          data-copy-value={card_external_id(@node)}
          role="button"
          tabindex="0"
          title="Copy id"
        >
          {short_external_id(card_external_id(@node))}
        </span>
      </footer>
    </article>
    """
  end

  # v0.26a M33: derive a status string from the most common prop names so
  # every card automatically renders a status pill when emitters set one.
  def card_status(node) do
    prop(node, :status, prop(node, :lifecycle_kind, prop(node, :state, nil)))
  end

  # The tile id (or objective_id, confirmation_id, analysis_id) is a useful
  # mono token to surface for copy-to-clipboard. Tile and ephemeral renderers
  # already expose `tile_id` / `confirmation_id` / `objective_id` props on
  # the catalog node; pick the first one present.
  def card_external_id(node) do
    prop(
      node,
      :objective_id,
      prop(
        node,
        :confirmation_id,
        prop(node, :analysis_id, prop(node, :tile_id, prop(node, :external_id, nil)))
      )
    )
  end

  def short_external_id(value) when is_binary(value) do
    case String.split(value, "_", parts: 2) do
      [prefix, rest] when byte_size(rest) > 8 ->
        "#{prefix}_#{String.slice(rest, 0, 8)}…"

      _ ->
        if byte_size(value) > 12, do: "#{String.slice(value, 0, 12)}…", else: value
    end
  end

  def short_external_id(_value), do: ""

  @status_classes %{
    "completed" => "workspace-status-success",
    "running" => "workspace-status-info",
    "open" => "workspace-status-info",
    "blocked" => "workspace-status-warn",
    "needs_confirmation" => "workspace-status-warn",
    "impasse" => "workspace-status-warn",
    "failed" => "workspace-status-danger",
    "denied" => "workspace-status-danger",
    "abandoned" => "workspace-status-neutral"
  }

  def status_class(status) when is_binary(status) do
    Map.get(@status_classes, String.downcase(status), "workspace-status-neutral")
  end

  def status_class(status) when is_atom(status) and not is_nil(status) do
    status_class(Atom.to_string(status))
  end

  def status_class(_status), do: "workspace-status-neutral"

  def humanize_status(value) when is_binary(value) do
    value
    |> String.replace("_", " ")
    |> String.trim()
  end

  def humanize_status(value) when is_atom(value) and not is_nil(value) do
    value
    |> Atom.to_string()
    |> humanize_status()
  end

  def humanize_status(_value), do: ""

  def assign_defaults(socket, assigns) do
    Phoenix.Component.assign(socket, assigns)
    |> Phoenix.Component.assign_new(:renderer_context, fn -> %{} end)
    |> Phoenix.Component.assign_new(:workspace_state, fn -> %{} end)
  end

  def component_class(_component, true) do
    "workspace-card workspace-card-stub"
  end

  def component_class(_component, false) do
    "workspace-card"
  end

  def dom_id(node), do: prop(node, :dom_id, "workspace-component-#{node.id}")

  def title(node, fallback), do: prop(node, :title, prop(node, :label, fallback))

  def component_title_id(%{id: node_id}), do: "workspace-component-title-#{node_id}"

  def summary(node, fallback) do
    prop(node, :body, prop(node, :text, prop(node, :subtitle, prop(node, :value, fallback))))
  end

  def metric(:canvas, context), do: count_metric(context, :canvas_tiles, "tile")

  def metric(:ephemeral_surface, context),
    do: count_metric(context, :ephemeral_surfaces, "surface")

  def metric(:badge_strip, context), do: count_metric(context, :active_objectives, "objective")
  def metric(_component, _context), do: nil

  def prop(%{props: props}, key, fallback) when is_map(props) do
    case Map.fetch(props, key) do
      {:ok, value} ->
        value

      :error ->
        Map.get(props, Atom.to_string(key), fallback)
    end
  end

  def prop(_node, _key, fallback), do: fallback

  def present?(value) when value in [nil, ""], do: false
  def present?(_value), do: true

  def component_icon(component), do: Catalog.icon_for(component)

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
