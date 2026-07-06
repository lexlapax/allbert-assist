defmodule AllbertAssistWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use AllbertAssistWeb, :html

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Surfaces.ContextBuilder
  alias AllbertAssistWeb.Components.WorkspaceSections
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

  attr :theme, :string,
    default: nil,
    doc: "v0.61b M7: current theme for the sidebar-footer toggle (SharedShellHooks assign)."

  attr :overflow_open?, :boolean, default: false
  attr :sidebar_state, :string, default: "expanded"

  attr :view_header?, :boolean,
    default: true,
    doc:
      "v0.61b M9.5 (S4 send-back): the landing keeps its hero composition — " <>
        "the M0 per-view header inventory assigns `/` no view-header band, so " <>
        "the hero page suppresses it and names the region via its own heading."

  slot :inner_block, required: true
  slot :view_actions

  def operator_shell(assigns) do
    assigns = assign(assigns, :nav_groups, nav_groups(assigns.active, assigns.nav_items))

    ~H"""
    <section
      id={@id}
      class="operator-shell"
      data-operator-shell={@active}
      data-workspace-shell="operator"
      data-active-page={@active}
      data-sidebar-state={@sidebar_state}
      role="region"
      aria-labelledby={@labelledby}
    >
      <.product_sidebar
        nav_groups={@nav_groups}
        theme={@theme}
        overflow_open?={@overflow_open?}
        sidebar_state={@sidebar_state}
      />

      <div class="operator-shell-main">
        <%!-- v0.61b M7 (ADR 0080 §2): the persistent topbar band is retired; a
        slim per-view header carries the view context inside the content area
        (suppressed on the landing hero per the M0 inventory — M9.5). --%>
        <div :if={@view_header?} class="operator-view-header">
          <div class="min-w-0">
            <h1 id={@labelledby} class="operator-view-title">{@title}</h1>
            <p :if={@subtitle} class="operator-view-subtitle">{@subtitle}</p>
          </div>
          <div :if={@view_actions != []} class="operator-view-actions">
            {render_slot(@view_actions)}
          </div>
        </div>

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

  attr :workspace, :map,
    default: nil,
    doc:
      "v0.61b M5 (ADR 0080 §1): contextual workspace sections nested under the " <>
        "Workspace entry. Present only on /workspace (the hosting LiveView owns " <>
        "the section events); operator shells pass nothing and render the plain " <>
        "pill — the Workspace entry is 'collapsed to its header' elsewhere."

  attr :theme, :string,
    default: nil,
    doc:
      "v0.61b M7 (ADR 0080 §2): current theme mode for the sidebar-footer theme " <>
        "toggle (relocation row 9). Events are owned by SharedShellHooks on every " <>
        "shell; nil hides the footer (non-LiveView renders)."

  attr :high_contrast?, :boolean, default: false
  attr :overflow_open?, :boolean, default: false

  attr :sidebar_state, :string,
    default: "expanded",
    values: ["expanded", "rail", "hidden"],
    doc:
      "v0.61b M8 (ADR 0080 §4): expanded (default) / icon rail / fully hidden. " <>
        "Owned by SharedShellHooks; persisted client-side by the LayoutPrefs hook."

  def product_sidebar(assigns) do
    assigns =
      assign(
        assigns,
        :nav_groups,
        assigns.nav_groups || nav_groups(assigns.active, assigns.nav_items)
      )

    ~H"""
    <aside
      id="product-sidebar"
      class="operator-sidebar"
      aria-label="Product navigation"
      data-sidebar-state={@sidebar_state}
      phx-hook="LayoutPrefs"
    >
      <div class="operator-sidebar-top">
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
        <button
          id="product-sidebar-toggle"
          type="button"
          class="allbert-icon-button operator-sidebar-toggle"
          phx-click="cycle_sidebar_state"
          aria-label="Toggle sidebar"
          title="Toggle sidebar (Cmd/Ctrl+B)"
          aria-expanded={if @sidebar_state == "expanded", do: "true", else: "false"}
          data-sidebar-state={@sidebar_state}
        >
          <.icon
            name={
              if @sidebar_state == "expanded",
                do: "hero-chevron-double-left-micro",
                else: "hero-chevron-double-right-micro"
            }
            class="size-4"
          />
        </button>
      </div>

      <nav class="operator-sidebar-nav" aria-label="Operator pages">
        <div :for={group <- @nav_groups} class="operator-nav-group">
          <p class="operator-nav-group-label">{group.label}</p>
          <%= for item <- group.items do %>
            <%= if item.key == "workspace" and @workspace && @sidebar_state == "rail" do %>
              <%!-- v0.61b M9.1: Escape returns focus to the invoking rail icon
              (ADR 0080 guardrail); click-away closes without stealing focus —
              the click target takes it (ARIA APG menu-button pattern). --%>
              <div
                class="operator-rail-flyout-wrap"
                phx-click-away="close_rail_flyout"
                phx-window-keydown={
                  JS.push("close_rail_flyout") |> JS.focus(to: "#operator-nav-workspace")
                }
                phx-key="escape"
              >
                <%!-- v0.61b M9.2: disclosure pattern (aria-expanded +
                aria-controls, no aria-haspopup) — haspopup="true" announces a
                menu, but the flyout is a grouped-sections panel. --%>
                <button
                  id="operator-nav-workspace"
                  type="button"
                  class={Patterns.nav_pill_class(item.active?)}
                  phx-click="toggle_rail_flyout"
                  aria-controls="operator-rail-flyout"
                  aria-expanded={
                    if Map.get(@workspace, :rail_flyout_open?), do: "true", else: "false"
                  }
                  aria-label="Workspace sections"
                  title={item.label}
                >
                  <span class="allbert-nav-pill-icon" aria-hidden="true">
                    <.icon name={nav_icon(item.key)} class="size-4" />
                  </span>
                  <span class="allbert-nav-pill-label">{item.label}</span>
                </button>
                <div
                  :if={Map.get(@workspace, :rail_flyout_open?)}
                  id="operator-rail-flyout"
                  class="operator-rail-flyout"
                  role="group"
                  aria-label="Workspace sections"
                >
                  <WorkspaceSections.workspace_sections workspace={@workspace} />
                </div>
              </div>
            <% else %>
              <%!-- v0.61b M9.2: explicit aria-label — in rail state the label
              span is display:none and the accessible name otherwise falls
              back to title, which is weaker than the M0 contract. --%>
              <Patterns.nav_pill
                id={"operator-nav-#{item.key}"}
                label={item.label}
                navigate={item.path}
                active?={item.active?}
                title={item.label}
                aria-label={item.label}
              >
                <:icon>
                  <.icon name={nav_icon(item.key)} class="size-4" />
                </:icon>
              </Patterns.nav_pill>
              <%= if item.key == "workspace" and @workspace && @sidebar_state == "expanded" do %>
                <WorkspaceSections.workspace_sections workspace={@workspace} />
              <% end %>
            <% end %>
          <% end %>
        </div>
      </nav>

      <div class="operator-sidebar-actions">
        <.link navigate={~p"/workspace"} class={Patterns.button_class!("primary")}>
          New chat
        </.link>
      </div>

      <%!-- v0.61b M7 (ADR 0080 §2, relocation rows 9/10/15): theme toggle +
      overflow menu re-home from the retired workspace appbar into the sidebar
      footer, rendering on every shell; SharedShellHooks owns their events. --%>
      <div :if={@theme} class="operator-sidebar-footer">
        <button
          id="workspace-theme-toggle"
          type="button"
          class="workspace-theme-toggle allbert-icon-button"
          phx-hook="ThemeSync"
          phx-click="toggle_workspace_theme"
          aria-label={theme_toggle_label(@theme)}
          title={theme_toggle_label(@theme)}
          data-current-theme={@theme}
          data-next-theme={next_workspace_theme(@theme)}
          data-high-contrast={if @high_contrast?, do: "true", else: "false"}
        >
          <.icon name={theme_toggle_icon(@theme)} class="size-4" />
          <span class="sr-only">{theme_toggle_label(@theme)}</span>
        </button>
        <%!-- v0.61b M9.1: Escape returns focus to the overflow trigger; see the
        rail-flyout note above for the click-away asymmetry. --%>
        <div
          class="allbert-overflow-wrap"
          phx-click-away="close_workspace_overflow_menu"
          phx-window-keydown={
            JS.push("close_workspace_overflow_menu") |> JS.focus(to: "#workspace-overflow-menu")
          }
          phx-key="escape"
        >
          <button
            id="workspace-overflow-menu"
            type="button"
            class="allbert-icon-button"
            aria-label="Workspace menu"
            title="Workspace menu"
            aria-haspopup="menu"
            aria-controls="workspace-overflow-menu-items"
            aria-expanded={if @overflow_open?, do: "true", else: "false"}
            phx-click="toggle_workspace_overflow_menu"
          >
            <.icon name="hero-ellipsis-horizontal-micro" class="size-5" />
          </button>
          <div
            :if={@overflow_open?}
            id="workspace-overflow-menu-items"
            class="workspace-overflow-menu"
            role="menu"
            aria-labelledby="workspace-overflow-menu"
            phx-hook="MenuKeys"
          >
            <button
              type="button"
              role="menuitem"
              class="workspace-tile-menu-item"
              phx-click="toggle_workspace_theme"
            >
              <.icon name={theme_toggle_icon(@theme)} class="size-4" />
              {theme_toggle_label(@theme)}
            </button>
            <.link
              id="workspace-overflow-settings-link"
              role="menuitem"
              class="workspace-tile-menu-item"
              {workspace_destination_link(@workspace, "workspace:settings")}
            >
              <.icon name="hero-adjustments-horizontal-micro" class="size-4" /> Workspace settings
            </.link>
            <.link role="menuitem" class="workspace-tile-menu-item" navigate={~p"/jobs"}>
              <.icon name="hero-clock-micro" class="size-4" /> Scheduled jobs
            </.link>
            <.link
              id="workspace-overflow-objectives-link"
              role="menuitem"
              class="workspace-tile-menu-item"
              {workspace_destination_link(@workspace, "workspace:objectives")}
            >
              <.icon name="hero-flag-micro" class="size-4" /> Objectives
            </.link>
            <button
              :if={@workspace && Map.get(@workspace, :thread_id)}
              id="workspace-thread-copy-id"
              type="button"
              role="menuitem"
              class="workspace-tile-menu-item workspace-copy-target"
              phx-hook="CopyToClipboard"
              data-copy-value={Map.get(@workspace, :thread_id)}
            >
              <.icon name="hero-clipboard-document-micro" class="size-4" /> Copy conversation id
            </button>
          </div>
        </div>
      </div>
    </aside>
    <%!-- v0.61b M8: slim reopen tab, the surviving affordance when the sidebar
    is fully hidden. M9.2: focus lands here as a RESULT of the hide action
    (SharedShellHooks pushes allbert:focus on the expanded/rail→hidden
    transition) — a phx-mounted JS.focus() stole focus on every navigation
    while hidden, bypassing the skip link. --%>
    <button
      :if={@sidebar_state == "hidden"}
      id="product-sidebar-reopen"
      type="button"
      class="operator-sidebar-reopen"
      phx-click="toggle_sidebar_hidden"
      aria-controls="product-sidebar"
      aria-expanded="false"
      aria-label="Reopen navigation"
      title="Reopen navigation (Cmd/Ctrl+Shift+B)"
    >
      <.icon name="hero-chevron-double-right-micro" class="size-4" />
    </button>
    """
  end

  # v0.61b M8/M9.4 — eight top-level rail icon assignments render here. Intents
  # keeps its flagged `hero-bolt` assignment as the workspace:intents destination,
  # not as a top-level pill.
  defp nav_icon("launch"), do: "hero-home-micro"
  defp nav_icon("workspace"), do: "hero-rectangle-group-micro"
  defp nav_icon("objectives"), do: "hero-flag-micro"
  defp nav_icon("jobs"), do: "hero-queue-list-micro"
  defp nav_icon("models"), do: "hero-cpu-chip-micro"
  defp nav_icon("channels"), do: "hero-signal-micro"
  defp nav_icon("settings"), do: "hero-cog-6-tooth-micro"
  defp nav_icon("trust"), do: "hero-shield-check-micro"
  defp nav_icon(_key), do: "hero-squares-2x2-micro"

  # v0.61b M7 — the M5 dispatch rule for workspace destinations: patch (live
  # update, no re-mount) when already on /workspace, navigate elsewhere.
  defp workspace_destination_link(workspace, destination) do
    path =
      case workspace && Map.get(workspace, :thread_id) do
        thread_id when is_binary(thread_id) and thread_id != "" ->
          ~p"/workspace?#{[thread_id: thread_id, destination: destination]}"

        _no_thread ->
          ~p"/workspace?#{[destination: destination]}"
      end

    if workspace, do: [patch: path], else: [navigate: path]
  end

  # v0.61b M7 — theme-toggle helpers lifted from the retired workspace appbar
  # (3-state cycle kept in sync with SharedShellHooks).
  defp next_workspace_theme("system"), do: "dark"
  defp next_workspace_theme("dark"), do: "light"
  defp next_workspace_theme("light"), do: "system"
  defp next_workspace_theme(_theme), do: "dark"

  defp theme_toggle_icon("dark"), do: "hero-sun-micro"
  defp theme_toggle_icon("light"), do: "hero-computer-desktop-micro"
  defp theme_toggle_icon(_theme), do: "hero-moon-micro"

  defp theme_toggle_label("system"), do: "Theme: system (switch to dark)"
  defp theme_toggle_label("dark"), do: "Theme: dark (switch to light)"
  defp theme_toggle_label("light"), do: "Theme: light (switch to system)"
  defp theme_toggle_label(_theme), do: "Switch workspace theme"

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
