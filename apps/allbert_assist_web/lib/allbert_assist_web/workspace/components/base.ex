defmodule AllbertAssistWeb.Workspace.Components.Base do
  @moduledoc """
  Shared renderer template for simple workspace catalog components.
  """

  use Phoenix.Component

  import AllbertAssistWeb.CoreComponents, only: [icon: 1]

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
      id={"workspace-component-#{@node.id}"}
      class={component_class(@component, @stub?)}
      data-workspace-component={@component}
      data-workspace-renderer="component"
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
        <span :if={@stub?} class="workspace-status-pill workspace-status-neutral">
          v0.26 stub
        </span>
      </header>

      <footer :if={metric(@component, @renderer_context)} class="workspace-card-footer">
        <span>{metric(@component, @renderer_context)}</span>
      </footer>
    </article>
    """
  end

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

  def component_icon(:trace_link), do: "hero-link-micro"
  def component_icon(:trace_viewer), do: "hero-document-text-micro"
  def component_icon(:objective_card), do: "hero-flag-micro"
  def component_icon(:confirmation_card), do: "hero-shield-check-micro"
  def component_icon(:approval_card), do: "hero-check-circle-micro"
  def component_icon(:approval_inspector), do: "hero-magnifying-glass-micro"
  def component_icon(:memory_review_card), do: "hero-book-open-micro"
  def component_icon(:job_card), do: "hero-clock-micro"
  def component_icon(:channel_card), do: "hero-inbox-micro"
  def component_icon(:settings_card), do: "hero-adjustments-horizontal-micro"
  def component_icon(:analysis_card), do: "hero-chart-bar-micro"
  def component_icon(:agent_report_card), do: "hero-document-chart-bar-micro"
  def component_icon(:parity_card), do: "hero-scale-micro"
  def component_icon(:debate_round_card), do: "hero-chat-bubble-left-right-micro"
  def component_icon(:button), do: "hero-play-micro"
  def component_icon(:action_button), do: "hero-bolt-micro"
  def component_icon(:status_badge), do: "hero-signal-micro"
  def component_icon(_component), do: "hero-squares-2x2-micro"

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
