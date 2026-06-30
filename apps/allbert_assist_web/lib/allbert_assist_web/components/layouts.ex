defmodule AllbertAssistWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AllbertAssistWeb, :html

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssistWeb.Workspace.Components.Patterns

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders your app layout.

  This function is typically invoked from every template,
  and it often contains your application menu, sidebar,
  or similar.

  ## Examples

      <Layouts.app flash={@flash}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_scope, :map,
    default: nil,
    doc: "the current [scope](https://hexdocs.pm/phoenix/scopes.html)"

  attr :content_width, :string,
    default: "narrow",
    values: ["narrow", "wide", "full"],
    doc: "the width of the inner content container"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <a
      id="skip-to-content"
      href="#main-content"
      class="sr-only focus:not-sr-only focus:fixed focus:left-4 focus:top-4 focus:z-50 focus:rounded focus:bg-base-100 focus:px-3 focus:py-2 focus:text-sm focus:font-semibold focus:outline-2 focus:outline-offset-2 focus:outline-base-content"
    >
      Skip to content
    </a>

    <main id="main-content" tabindex="-1" class={main_class(@content_width)}>
      <div class={content_container_class(@content_width)}>
        {render_slot(@inner_block)}
      </div>
    </main>

    <.flash_group flash={@flash} />
    """
  end

  @doc """
  Shared operator app shell for web surfaces that are not the full workspace tree.
  """
  attr :id, :string, default: "operator-shell"
  attr :active, :string, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil
  attr :labelledby, :string, default: "operator-shell-title"
  attr :nav_items, :list, default: nil

  slot :inner_block, required: true

  def operator_shell(assigns) do
    ~H"""
    <section
      id={@id}
      class="operator-shell"
      data-operator-shell={@active}
      data-workspace-shell="operator"
      data-active-page={@active}
      role="region"
      aria-labelledby={@labelledby}
    >
      <header class="allbert-appbar operator-shell-appbar">
        <div class="allbert-appbar-brand">
          <span class="allbert-brand-icon" aria-hidden="true">
            <.icon name="hero-window-micro" class="size-4" />
          </span>
          <div class="min-w-0">
            <h1 id={@labelledby} class="allbert-appbar-title">{@title}</h1>
            <p :if={@subtitle} class="allbert-appbar-subtitle">{@subtitle}</p>
          </div>
        </div>

        <nav class="allbert-appbar-center operator-shell-nav" aria-label="Operator pages">
          <.link
            :for={item <- operator_nav_items(@active, @nav_items)}
            navigate={item.path}
            class={["operator-shell-nav-link", item.active? && "operator-shell-nav-link-active"]}
            aria-current={if(item.active?, do: "page")}
          >
            {item.label}
          </.link>
        </nav>

        <div class="allbert-appbar-actions">
          <.link navigate={~p"/workspace"} class={Patterns.button_class!("secondary")}>
            Workspace
          </.link>
        </div>
      </header>

      <nav
        id="operator-mobile-shellbar"
        class="operator-mobile-shellbar"
        aria-label="Operator pages"
      >
        <.link
          :for={item <- operator_nav_items(@active, @nav_items)}
          navigate={item.path}
          class={[
            "operator-mobile-shellbar-link",
            item.active? && "operator-mobile-shellbar-link-active"
          ]}
          aria-current={if(item.active?, do: "page")}
        >
          {item.label}
        </.link>
      </nav>

      <div class="operator-shell-body">
        {render_slot(@inner_block)}
      </div>
    </section>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={show(".phx-client-error #client-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={show(".phx-server-error #server-error") |> JS.remove_attribute("hidden")}
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  defp main_class("full"), do: "allbert-page min-h-screen bg-base-100"

  defp main_class(_width),
    do: "allbert-page min-h-screen bg-base-100 px-4 py-8 sm:px-6 lg:px-8"

  defp content_container_class("full"), do: "w-full"
  defp content_container_class("wide"), do: "mx-auto max-w-6xl space-y-4"
  defp content_container_class(_width), do: "mx-auto max-w-2xl space-y-4"

  defp operator_nav_items(active, nil) do
    [
      %{label: "Workspace", path: ~p"/workspace", active?: active == "workspace"},
      %{label: "Jobs", path: ~p"/jobs", active?: active == "jobs"},
      %{label: "Objectives", path: ~p"/workspace", active?: active == "objectives"}
    ]
  end

  defp operator_nav_items(active, nav_items) when is_list(nav_items) do
    Enum.map(nav_items, fn item ->
      active_key = Map.get(item, :active_key) || Map.get(item, "active_key")

      %{
        label: Map.get(item, :label) || Map.get(item, "label"),
        path: Map.get(item, :path) || Map.get(item, "path"),
        active?: active_key == active
      }
    end)
  end

  defp static_asset_version do
    :allbert_assist_web
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp theme_asset_version, do: AllbertAssist.Theme.Version.stylesheet_version()

  defp root_theme_attribute(settings) do
    case setting_value(settings, "workspace.theme.mode", "system") do
      "dark" -> "dark"
      "light" -> "light"
      _theme -> nil
    end
  end

  defp root_high_contrast_attribute(settings) do
    bool_attribute(setting_value(settings, "workspace.accessibility.high_contrast", false))
  end

  defp root_reduce_motion_attribute(settings) do
    bool_attribute(setting_value(settings, "workspace.accessibility.reduce_motion", false))
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(_value), do: nil

  defp root_settings_snapshot do
    case Runner.run("resolved_settings_snapshot", %{}, root_read_context()) do
      {:ok, %{status: :completed, settings: settings}} when is_map(settings) ->
        settings

      _other ->
        AllbertAssist.Settings.defaults()
    end
  end

  defp root_read_context do
    ContextBuilder.live_view_context(%{}, surface: "AllbertAssistWeb.Layouts")
  end

  defp setting_value(settings, key, default) when is_map(settings) do
    get_in(settings, String.split(key, ".")) || default
  end
end
