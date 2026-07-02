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

  attr :visual_direction, :string,
    default: nil,
    doc:
      "optional v0.60b preview-only visual-direction id (a|b|c|selected); drives the " <>
        "[data-visual-direction] token/theme delta on disposable styled-variant routes"

  attr :layout_system, :string,
    default: nil,
    doc:
      "optional v0.61 preview-only layout-system id (a|b|c|d); drives the " <>
        "[data-layout-system] zone-composition delta on disposable layout-exploration routes"

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

    <main
      id="main-content"
      tabindex="-1"
      class={main_class(@content_width)}
      data-visual-direction={@visual_direction}
      data-layout-system={@layout_system}
    >
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

  attr :visual_direction, :string,
    default: nil,
    doc:
      "optional v0.60b preview-only visual-direction id (a|b|c|selected); drives the " <>
        "[data-visual-direction] token/theme delta on disposable styled-variant routes"

  attr :layout_system, :string,
    default: nil,
    doc:
      "optional v0.61 preview-only layout-system id (a|b|c|d); drives the " <>
        "[data-layout-system] zone-composition delta on disposable layout-exploration routes"

  slot :inner_block, required: true

  def operator_shell(assigns) do
    assigns = assign(assigns, :nav_groups, nav_groups(assigns.active, assigns.nav_items))

    ~H"""
    <section
      id={@id}
      class="operator-shell"
      data-operator-shell={@active}
      data-workspace-shell="operator"
      data-active-page={@active}
      data-visual-direction={@visual_direction}
      data-layout-system={@layout_system}
      role="region"
      aria-labelledby={@labelledby}
    >
      <.product_sidebar nav_groups={@nav_groups} />

      <div class="operator-shell-main">
        <header class="operator-shell-topbar">
          <div class="min-w-0">
            <h1 id={@labelledby} class="allbert-appbar-title">{@title}</h1>
            <p :if={@subtitle} class="allbert-appbar-subtitle">{@subtitle}</p>
          </div>
        </header>

        <div class="operator-shell-body">
          {render_slot(@inner_block)}
        </div>
      </div>

      <nav
        id="operator-mobile-shellbar"
        class="operator-mobile-shellbar"
        aria-label="Operator pages"
      >
        <.link navigate={~p"/"} class="operator-mobile-shellbar-brand" aria-label="Allbert home">
          <img
            src={~p"/images/allbert-mark.svg"}
            alt=""
            aria-hidden="true"
            width="24"
            height="24"
            class="operator-brand-mark"
          />
          <span class="operator-mobile-shellbar-wordmark">Allbert</span>
        </.link>
        <.link
          :for={item <- Enum.flat_map(@nav_groups, & &1.items)}
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
    </section>
    """
  end

  @doc """
  The persistent Layout D product sidebar (brand + grouped IA navigation + primary
  action). Shared by `operator_shell/1` and the `/workspace` shell so the desktop
  navigation cannot drift between the two, and the workspace surface carries the same
  chosen-layout navigation as every other surface (v0.61 M10.3 P0-8).

  Pass either precomputed `nav_groups`, or an `active` key (and optional `nav_items`)
  to have the canonical IA groups computed here.
  """
  attr :nav_groups, :list, default: nil
  attr :active, :string, default: nil
  attr :nav_items, :list, default: nil

  def product_sidebar(assigns) do
    assigns =
      assign(
        assigns,
        :nav_groups,
        assigns.nav_groups || nav_groups(assigns.active, assigns.nav_items)
      )

    ~H"""
    <aside class="operator-sidebar" aria-label="Product navigation">
      <.link navigate={~p"/"} class="operator-sidebar-brand">
        <img
          src={~p"/images/allbert-mark.svg"}
          alt=""
          aria-hidden="true"
          width="28"
          height="28"
          class="operator-brand-mark"
        />
        <span class="operator-sidebar-wordmark">Allbert</span>
      </.link>

      <nav class="operator-sidebar-nav" aria-label="Operator pages">
        <div :for={group <- @nav_groups} class="operator-nav-group">
          <p class="operator-nav-group-label">{group.label}</p>
          <Patterns.nav_pill
            :for={item <- group.items}
            id={"operator-nav-#{item.key}"}
            label={item.label}
            navigate={item.path}
            active?={item.active?}
          />
        </div>
      </nav>

      <div class="operator-sidebar-actions">
        <.link navigate={~p"/workspace"} class={Patterns.button_class!("primary")}>
          New chat
        </.link>
      </div>
    </aside>
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

  # The canonical v0.60 IA navigation model (ADR 0077): five stable groups —
  # Start / Work / Operate / Extend / Trust — reaching all nine IA surfaces in the
  # M2-chosen Layout D sidebar. Onboarding is a start-surface affordance (seated on
  # launch + the workspace empty state per the M4 route table), not a nav tab.
  # models/channels/settings/trust are workspace destinations, not standalone routes.
  defp nav_groups(active, nil) do
    [
      %{label: "Start", items: [nav_item(active, "launch", "Home", ~p"/")]},
      %{
        label: "Work",
        items: [
          nav_item(active, "workspace", "Workspace", ~p"/workspace"),
          nav_item(active, "objectives", "Objectives", ~p"/objectives")
        ]
      },
      %{
        label: "Operate",
        items: [
          nav_item(active, "jobs", "Jobs", ~p"/jobs"),
          nav_item(active, "models", "Models", "/workspace?destination=workspace:models")
        ]
      },
      %{
        label: "Extend",
        items: [
          nav_item(active, "channels", "Channels", "/workspace?destination=workspace:channels")
        ]
      },
      %{
        label: "Trust",
        items: [
          nav_item(active, "settings", "Settings", "/workspace?destination=workspace:settings"),
          nav_item(active, "trust", "Trust", "/workspace?destination=workspace:surface_policy")
        ]
      }
    ]
  end

  # Explicit nav items (the disposable preview surfaces) are grouped by their
  # declared nav_group so the same D sidebar renders the walking-skeleton surfaces.
  defp nav_groups(active, nav_items) when is_list(nav_items) do
    nav_items
    |> Enum.map(fn item ->
      key = Map.get(item, :active_key) || Map.get(item, "active_key")

      %{
        key: key,
        label: Map.get(item, :label) || Map.get(item, "label"),
        path: Map.get(item, :path) || Map.get(item, "path"),
        active?: key == active,
        group: Map.get(item, :nav_group) || Map.get(item, "nav_group") || "Pages"
      }
    end)
    |> Enum.chunk_by(& &1.group)
    |> Enum.map(fn items -> %{label: hd(items).group, items: items} end)
  end

  defp nav_item(active, key, label, path) do
    %{key: key, label: label, path: path, active?: key == active}
  end

  defp static_asset_version do
    :allbert_assist_web
    |> Application.spec(:vsn)
    |> to_string()
  end

  defp theme_asset_version, do: AllbertAssist.Theme.Version.stylesheet_version()

  # v0.61 M9 — emit an explicit `system` theme mode (was nil, which silently fell back
  # to light). The client/CSS layer resolves `data-theme="system"` against the OS
  # `prefers-color-scheme` (see the @media (prefers-color-scheme: dark) block in
  # app.css); explicit light/dark still win. The server cannot know the OS preference,
  # so this function only names the mode — it must not guess dark/light for `system`.
  defp root_theme_attribute(settings) do
    case setting_value(settings, "workspace.theme.mode", "system") do
      "dark" -> "dark"
      "light" -> "light"
      _system -> "system"
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
