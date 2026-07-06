# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.Workspace do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :workspace,
    description: "Workspace container",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"workspace-component-#{@node.id}"}
      class="workspace-root-sentinel"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <h2 id={Base.component_title_id(@node)} class="sr-only">
        Allbert workspace
      </h2>
    </div>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.WorkspaceShell do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :workspace_shell,
    description: "Workspace shell",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"workspace-component-#{@node.id}"}
      class="workspace-root-sentinel"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <h2 id={Base.component_title_id(@node)} class="sr-only">
        Allbert workspace
      </h2>
    </div>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.NavRail do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :nav_rail,
    description: "Workspace navigation rail",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id="workspace-launcher"
      class="workspace-nav-rail-shell"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      phx-click-away="close_workspace_launcher"
      phx-window-keydown="close_workspace_launcher"
      phx-key="escape"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <div class="workspace-rail-head">
        <h2 id={Base.component_title_id(@node)} class="workspace-rail-title">Workspace</h2>
        <button
          id="workspace-rail-new-thread"
          type="button"
          class="allbert-icon-button"
          phx-click="new_thread"
          aria-label="New conversation"
          title="New conversation"
        >
          <.icon name="hero-plus-micro" class="size-4" />
        </button>
      </div>
    </aside>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.ThreadList do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :thread_list,
    description: "Recent workspace threads",
    custom?: true

  import AllbertAssistWeb.Components.ThreadRow, only: [thread_row: 1]

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> Base.assign_defaults(assigns)
     |> assign(
       recent_threads: Map.get(context, :recent_threads, []),
       thread_id: Map.get(context, :thread_id),
       renaming_thread_id: Map.get(context, :renaming_thread_id)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-thread-list"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <h3 id={Base.component_title_id(@node)} class="workspace-rail-section-title">
        Conversations
      </h3>
      <div class="workspace-rail-list" role="list">
        <.thread_row
          :for={thread <- @recent_threads}
          thread={thread}
          active?={thread.id == @thread_id}
          renaming?={thread.id == @renaming_thread_id}
        />
        <p :if={@recent_threads == []} class="workspace-rail-empty">No conversations yet.</p>
      </div>
    </section>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.AppLauncher do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :app_launcher,
    description: "Workspace app launcher",
    custom?: true

  alias AllbertAssist.Theme.Layout
  alias AllbertAssist.Workspace.Catalog, as: WorkspaceCatalog
  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    context = Map.get(assigns, :renderer_context, %{})
    registered_apps = Map.get(context, :registered_apps, [])
    layout = Base.prop(Map.get(assigns, :node), :layout, %{})

    destinations =
      layout
      |> Layout.launcher_destinations(
        WorkspaceCatalog.known_destinations(%{registered_apps: registered_apps})
      )

    {:ok,
     socket
     |> Base.assign_defaults(assigns)
     |> assign(
       canvas_destination: Map.get(context, :canvas_destination, "output"),
       destinations: destinations
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-app-launcher"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <div :for={{section, destinations} <- launcher_sections(@destinations)}>
        <h3
          id={if section == :output, do: Base.component_title_id(@node), else: nil}
          class={[
            "workspace-rail-section-title",
            section != :output && "workspace-rail-section-spaced"
          ]}
        >
          {section_label(section)}
        </h3>
        <div class="workspace-rail-list" role="list">
          <button
            :for={destination <- destinations}
            id={"workspace-dest-#{destination.dom_id}"}
            type="button"
            role="listitem"
            class={[
              "workspace-rail-item workspace-destination-item",
              destination.section == :apps && "workspace-app-launcher-item",
              destination_active?(destination.id, @canvas_destination) &&
                "workspace-rail-item-active"
            ]}
            phx-click="select_destination"
            phx-value-destination={destination.id}
            data-destination={destination.id}
            data-app-id={Map.get(destination, :app_id)}
            aria-pressed={bool_attribute(destination_active?(destination.id, @canvas_destination))}
            title={destination.label}
          >
            <span class="workspace-app-icon" aria-hidden="true">
              <.icon name={destination_icon(destination)} class="size-4" />
            </span>
            <span class="workspace-rail-item-title">{destination.label}</span>
          </button>
        </div>
      </div>
    </section>
    """
  end

  defp destination_active?(destination, active_destination), do: destination == active_destination

  defp launcher_sections(destinations) do
    destinations
    |> Enum.chunk_by(& &1.section)
    |> Enum.map(fn entries ->
      {hd(entries).section, entries}
    end)
  end

  defp section_label(:output), do: "Output"
  defp section_label(:apps), do: "Apps"
  defp section_label(:workspace), do: "Workspace"

  defp destination_icon(%{id: "output"}), do: "hero-rectangle-stack-micro"
  defp destination_icon(%{id: "workspace:onboard"}), do: "hero-sparkles-micro"
  defp destination_icon(%{id: "workspace:create"}), do: "hero-plus-circle-micro"
  defp destination_icon(%{id: "workspace:discover"}), do: "hero-magnifying-glass-micro"
  defp destination_icon(%{id: "workspace:marketplace"}), do: "hero-shopping-bag-micro"
  defp destination_icon(%{id: "workspace:calendar"}), do: "hero-calendar-days-micro"
  defp destination_icon(%{id: "workspace:mail"}), do: "hero-inbox-micro"
  defp destination_icon(%{id: "workspace:github"}), do: "hero-code-bracket-square-micro"
  defp destination_icon(%{id: "workspace:jobs"}), do: "hero-clock-micro"
  defp destination_icon(%{id: "workspace:objectives"}), do: "hero-flag-micro"
  defp destination_icon(%{id: "workspace:confirmations"}), do: "hero-shield-check-micro"
  defp destination_icon(%{id: "workspace:security"}), do: "hero-shield-exclamation-micro"
  defp destination_icon(%{id: "workspace:settings"}), do: "hero-adjustments-horizontal-micro"

  defp destination_icon(%{section: :apps, app_id: app_id}) do
    case app_id do
      "stocksage" -> "hero-chart-bar-micro"
      "notes_files" -> "hero-document-text-micro"
      _app_id -> "hero-squares-2x2-micro"
    end
  end

  defp destination_icon(_destination), do: "hero-squares-2x2-micro"

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"
end

defmodule AllbertAssistWeb.Workspace.Components.UtilityDrawer do
  @moduledoc """
  Retained-but-unused `:utility_drawer` implementation (the v0.61b/v0.62
  registered-but-unused catalog carve-out; the Header-stub precedent).

  The drawer presentation retired at v0.34 and its `drawer_shell_*` pattern
  helpers + CSS were removed at v0.62 M0.1 — this inert stub keeps the atom
  renderable (no dead pattern calls, no legacy classes, hidden by default) if
  a tree ever re-adds it.
  """
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :utility_drawer,
    description: "Workspace utility drawer",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    {:ok, Base.assign_defaults(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <aside
      id={"workspace-component-#{@node.id}"}
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-retired="true"
      aria-labelledby={Base.component_title_id(@node)}
      aria-hidden="true"
      hidden
    >
      <h2 id={Base.component_title_id(@node)} class="sr-only">Retired workspace utility drawer</h2>
      <p class="sr-only">
        Workspace tools now render through Canvas destinations in the v0.34 shell.
      </p>
    </aside>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.WorkspacePanel do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :workspace_panel,
    description: "Workspace zone panel"
end

defmodule AllbertAssistWeb.Workspace.Components.Canvas do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :canvas,
    description: "Persistent per-thread canvas",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> Base.assign_defaults(assigns)
     |> assign(
       canvas_tiles: Map.get(context, :canvas_tiles, []),
       max_tiles: Map.get(context, :workspace_canvas_max_tiles_per_thread, 64),
       workspace_badges: Map.get(context, :workspace_badges, []),
       canvas_focus?: Map.get(context, :canvas_focus?, false),
       # v0.61b M7 (relocation row 8): the ephemeral count chip re-homes from
       # the retired appbar into the pane header.
       ephemeral_surfaces: Map.get(context, :ephemeral_surfaces, [])
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id="workspace-canvas"
      class="workspace-pane-header workspace-canvas-header"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-workspace-canvas-node={@node.id}
      data-destination={Base.prop(@node, :destination, "output")}
      aria-labelledby={Base.component_title_id(@node)}
    >
      <div class="workspace-pane-title-block">
        <h2 id={Base.component_title_id(@node)} class="workspace-pane-title">
          {destination_label(Base.prop(@node, :destination, "output"))}
        </h2>
        <p class="workspace-pane-subtitle">
          {destination_summary(Base.prop(@node, :destination, "output"))}
        </p>
      </div>
      <div class="workspace-pane-actions" aria-label="Canvas state">
        <span
          id="workspace-canvas-cap-chip"
          class={["allbert-chip", near_canvas_cap?(@canvas_tiles, @max_tiles) && "allbert-chip-warn"]}
        >
          <.icon name="hero-rectangle-stack-micro" class="size-4" />
          {length(@canvas_tiles)}/{@max_tiles} tiles
        </span>
        <span :if={@workspace_badges != []} class="allbert-chip allbert-chip-warn">
          <.icon name="hero-exclamation-triangle-micro" class="size-4" />
          {length(@workspace_badges)} notice(s)
        </span>
        <a
          id="workspace-ephemeral-count-chip"
          href="#workspace-node-workspace-ephemeral-region"
          class="allbert-chip allbert-chip-link"
          title="Jump to ephemerals"
        >
          <.icon name="hero-bolt-micro" class="size-4" />
          {length(@ephemeral_surfaces)} ephemeral{if length(@ephemeral_surfaces) == 1,
            do: "",
            else: "s"}
        </a>
        <button
          id="workspace-canvas-focus"
          type="button"
          class="allbert-icon-button workspace-pane-maximize"
          phx-click="toggle_canvas_focus"
          aria-pressed={bool_attribute(@canvas_focus?)}
          aria-label={focus_label(@canvas_focus?)}
          title={focus_label(@canvas_focus?)}
        >
          <.icon
            name={
              if @canvas_focus?,
                do: "hero-arrows-pointing-in-micro",
                else: "hero-arrows-pointing-out-micro"
            }
            class="size-4"
          />
        </button>
      </div>
    </section>
    """
  end

  # v0.61b M9.1: this is the maximize/restore control on the docked pane — the
  # old "Open/Close canvas drawer" label misnamed both the action and the
  # retired floating presentation.
  defp focus_label(true), do: "Restore canvas pane"
  defp focus_label(false), do: "Maximize canvas pane"

  defp destination_label("output"), do: "Output"
  defp destination_label("app:" <> app_id), do: app_id |> humanize_destination()
  defp destination_label("workspace:" <> tool), do: tool |> humanize_destination()
  defp destination_label(_destination), do: "Output"

  defp destination_summary("output"), do: "Persistent workspace output for this thread."
  defp destination_summary("app:" <> _app_id), do: "App dashboard and workspace panels."
  defp destination_summary("workspace:" <> _tool), do: "Workspace tool panel."
  defp destination_summary(_destination), do: "Persistent workspace output for this thread."

  defp humanize_destination(value) do
    value
    |> String.replace(["_", "-"], " ")
    |> String.split(" ", trim: true)
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"

  defp near_canvas_cap?(tiles, max_tiles) when is_list(tiles) and is_integer(max_tiles) do
    max_tiles > 0 and length(tiles) / max_tiles >= 0.8
  end

  defp near_canvas_cap?(_tiles, _max_tiles), do: false
end

defmodule AllbertAssistWeb.Workspace.Components.Tile do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tile,
    description: "Editable and read-only canvas tile",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.{Base, Patterns}

  @impl true
  def update(assigns, socket) do
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> Base.assign_defaults(assigns)
     |> assign(
       user_id: Map.get(context, :user_id),
       thread_id: Map.get(context, :thread_id),
       offline_enabled?: Map.get(context, :workspace_offline_enabled?, true),
       indexeddb_quota_bytes: Map.get(context, :workspace_indexeddb_quota_bytes, 33_554_432),
       open_tile_menu_id: Map.get(context, :open_tile_menu_id)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class={[
        "workspace-tile",
        Base.prop(@node, :pinned?, false) && "workspace-tile-pinned",
        Base.prop(@node, :deleted?, false) && "workspace-tile-deleted"
      ]}
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-workspace-tile-id={Base.prop(@node, :tile_id, nil)}
      data-workspace-tile-kind={Base.prop(@node, :tile_kind, "tile")}
      data-workspace-tile-pinned={bool_attribute(Base.prop(@node, :pinned?, false))}
      data-workspace-tile-deleted={bool_attribute(Base.prop(@node, :deleted?, false))}
      aria-labelledby={Base.component_title_id(@node)}
    >
      <header class="workspace-tile-header">
        <span class="workspace-tile-kind-icon" aria-hidden="true">
          <.icon name={tile_icon(@node)} class="size-4" />
        </span>
        <div class="workspace-tile-title-block">
          <h2 id={Base.component_title_id(@node)} class="workspace-tile-title">
            {Base.title(@node, "Canvas tile")}
          </h2>
          <p class="workspace-tile-meta">
            <span>{tile_kind_label(@node)}</span>
            <span :if={tile_id(@node)} class="workspace-mono">{short_id(tile_id(@node))}</span>
          </p>
        </div>
        <div class="workspace-tile-actions">
          <span :if={Base.prop(@node, :pinned?, false)} class="workspace-status-pill">
            <.icon name="hero-bookmark-micro" class="size-4" /> pinned
          </span>
          <span
            :if={Base.prop(@node, :deleted?, false)}
            class="workspace-status-pill workspace-status-warn"
          >
            deleted
          </span>
          <button
            type="button"
            id={tile_action_id(@node)}
            class="allbert-icon-button workspace-tile-action"
            aria-label={tile_action_label(@node, Base.title(@node, "canvas tile"))}
            title={tile_action_title(@node)}
            phx-click="manage_workspace_tile"
            phx-value-tile-id={tile_id(@node)}
            phx-value-operation={tile_primary_operation(@node)}
            phx-disable-with
            disabled={tile_action_disabled?(@node)}
          >
            <.icon name={tile_action_icon(@node)} class="size-4" />
          </button>
          <button
            type="button"
            id={tile_menu_button_id(@node)}
            class="allbert-icon-button workspace-tile-action"
            aria-label={"Open #{Base.title(@node, "canvas tile")} menu"}
            title="Tile menu"
            aria-haspopup="menu"
            aria-expanded={bool_attribute(tile_menu_open?(@node, @open_tile_menu_id))}
            aria-controls={tile_menu_id(@node)}
            phx-click="toggle_workspace_tile_menu"
            phx-value-tile-id={tile_id(@node)}
            disabled={tile_action_disabled?(@node)}
          >
            <.icon name="hero-ellipsis-horizontal-micro" class="size-4" />
          </button>

          <div
            :if={tile_menu_open?(@node, @open_tile_menu_id)}
            id={tile_menu_id(@node)}
            class="workspace-tile-menu"
            role="menu"
            aria-labelledby={tile_menu_button_id(@node)}
            phx-hook="MenuKeys"
          >
            <button
              type="button"
              role="menuitem"
              class="workspace-tile-menu-item"
              phx-click="manage_workspace_tile"
              phx-value-tile-id={tile_id(@node)}
              phx-value-operation={tile_primary_operation(@node)}
              phx-disable-with
            >
              <.icon name={tile_action_icon(@node)} class="size-4" />
              {tile_menu_primary_label(@node)}
            </button>
            <button
              :if={tile_id(@node)}
              type="button"
              role="menuitem"
              class="workspace-tile-menu-item"
              id={"workspace-tile-inspect-#{tile_id(@node)}"}
              phx-click="open_tile_inspector"
              phx-value-tile-id={tile_id(@node)}
            >
              <.icon name="hero-magnifying-glass-micro" class="size-4" /> Inspect
            </button>
            <button
              :if={tile_id(@node)}
              type="button"
              role="menuitem"
              class="workspace-tile-menu-item"
              id={"workspace-tile-copy-id-#{@node.id}"}
              phx-hook="CopyToClipboard"
              data-copy-value={tile_id(@node)}
              title="Copy tile id"
            >
              <.icon name="hero-clipboard-document-micro" class="size-4" /> Copy tile id
            </button>
            <button
              :if={!deleted?(@node)}
              type="button"
              role="menuitem"
              class="workspace-tile-menu-item workspace-tile-menu-item-danger"
              phx-click="manage_workspace_tile"
              phx-value-tile-id={tile_id(@node)}
              phx-value-operation="remove"
              phx-disable-with
            >
              <.icon name="hero-trash-micro" class="size-4" /> Remove tile
            </button>
          </div>
        </div>
      </header>

      <div
        :if={editable?(@node, @offline_enabled?)}
        id={editor_id(@node)}
        class="workspace-tile-editor"
        data-workspace-tile-editor="true"
        data-tile-id={Base.prop(@node, :tile_id, "")}
        data-thread-id={@thread_id}
        data-user-id={@user_id}
        data-kind={Base.prop(@node, :tile_kind, "text")}
        data-base-revision-id={Base.prop(@node, :base_revision_id, "")}
        data-quota-bytes={@indexeddb_quota_bytes}
        phx-hook="WorkspaceTileEditor"
        phx-update="ignore"
      >
        <label class="sr-only" for={editor_input_id(@node)}>
          {Base.title(@node, "Canvas tile")}
        </label>
        <textarea
          id={editor_input_id(@node)}
          class="workspace-tile-editor-input"
          data-workspace-editor-input="true"
          spellcheck="true"
        >{Base.prop(@node, :tile_text, "")}</textarea>
        <p class="workspace-tile-editor-status" data-workspace-editor-status="true">
          Saved locally
        </p>
      </div>

      <pre :if={readonly_summary?(@node, @offline_enabled?)} class="workspace-tile-readonly">
    {Base.summary(@node, "Canvas tile")}
      </pre>

      <Patterns.status_callout
        :if={conflict?(@node)}
        id={"workspace-tile-conflict-#{@node.id}"}
        class="workspace-conflict-banner"
        data-workspace-conflict-banner="true"
        tone="warning"
      >
        <p>
          Conflict reconciled. {conflict_count(@node)} offline edit(s) were merged into this
          tile.
        </p>
        <button
          :if={revert_revision_id(@node)}
          type="button"
          class={Patterns.button_class!("secondary", "mt-2")}
          phx-click="revert_tile_revision"
          phx-value-tile-id={Base.prop(@node, :tile_id, "")}
          phx-value-revision-id={revert_revision_id(@node)}
        >
          Revert
        </button>
      </Patterns.status_callout>

      <footer class="workspace-tile-footer">
        <span class="workspace-mono">
          emitter {Base.prop(@node, :emitter_id, "workspace")}
        </span>
        <time :if={Base.prop(@node, :updated_at, nil)} datetime={Base.prop(@node, :updated_at, nil)}>
          {Base.prop(@node, :updated_at, nil)}
        </time>
      </footer>
    </section>
    """
  end

  defp editable?(node, true), do: Base.prop(node, :editable?, false) == true
  defp editable?(_node, false), do: false

  defp readonly_summary?(node, offline_enabled?) do
    !editable?(node, offline_enabled?) and node.children == [] and
      Base.present?(Base.summary(node, nil))
  end

  defp editor_id(node), do: "workspace-tile-editor-#{Base.prop(node, :tile_id, node.id)}"

  defp editor_input_id(node) do
    "workspace-tile-editor-input-#{Base.prop(node, :tile_id, node.id)}"
  end

  defp tile_kind_label(node) do
    node
    |> Base.prop(:tile_kind, "tile")
    |> to_string()
    |> then(&"#{&1} tile")
  end

  defp tile_icon(node) do
    case Base.prop(node, :tile_kind, "tile") |> to_string() do
      "text" -> "hero-document-text-micro"
      "markdown" -> "hero-document-text-micro"
      "approval_card" -> "hero-check-circle-micro"
      "confirmation_card" -> "hero-shield-check-micro"
      "objective_card" -> "hero-flag-micro"
      "analysis_card" -> "hero-chart-bar-micro"
      _other -> "hero-squares-2x2-micro"
    end
  end

  defp tile_id(node), do: Base.prop(node, :tile_id, nil)

  defp pinned?(node), do: Base.prop(node, :pinned?, false) == true
  defp deleted?(node), do: Base.prop(node, :deleted?, false) == true

  defp tile_action_disabled?(node), do: is_nil(tile_id(node))

  defp tile_primary_operation(node) do
    cond do
      deleted?(node) -> "restore"
      pinned?(node) -> "unpin"
      true -> "pin"
    end
  end

  defp tile_action_label(node, title) do
    case tile_primary_operation(node) do
      "restore" -> "Restore #{title}"
      "unpin" -> "Unpin #{title}"
      "pin" -> "Pin #{title}"
    end
  end

  defp tile_action_title(node) do
    case tile_primary_operation(node) do
      "restore" -> "Restore tile"
      "unpin" -> "Unpin tile"
      "pin" -> "Pin tile"
    end
  end

  defp tile_menu_primary_label(node) do
    case tile_primary_operation(node) do
      "restore" -> "Restore tile"
      "unpin" -> "Unpin tile"
      "pin" -> "Pin tile"
    end
  end

  defp tile_action_icon(node) do
    case tile_primary_operation(node) do
      "restore" -> "hero-arrow-path-micro"
      "unpin" -> "hero-bookmark-slash-micro"
      "pin" -> "hero-bookmark-micro"
    end
  end

  defp tile_action_id(node), do: dom_id("workspace-tile-action", tile_id(node))
  defp tile_menu_button_id(node), do: dom_id("workspace-tile-menu-button", tile_id(node))
  defp tile_menu_id(node), do: dom_id("workspace-tile-menu", tile_id(node))

  defp tile_menu_open?(node, open_tile_menu_id) do
    id = tile_id(node)
    is_binary(id) and id == open_tile_menu_id
  end

  defp dom_id(_prefix, nil), do: nil
  defp dom_id(prefix, id), do: "#{prefix}-#{id}"

  defp short_id(nil), do: nil

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 16, do: String.slice(id, 0, 12) <> "...", else: id
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"

  defp conflict?(node), do: conflict_value(node, :conflict?, false) == true
  defp conflict_count(node), do: conflict_value(node, :conflict_count, 0)
  defp revert_revision_id(node), do: conflict_value(node, :revert_revision_id, nil)

  defp conflict_value(node, key, fallback) do
    case Base.prop(node, :conflict_summary, %{}) do
      summary when is_map(summary) ->
        Map.get(summary, key) || Map.get(summary, Atom.to_string(key)) || fallback

      _other ->
        fallback
    end
  end
end

defmodule AllbertAssistWeb.Workspace.Components.EphemeralSurface do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :ephemeral_surface,
    description: "Shared ephemeral surface",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> Base.assign_defaults(assigns)
     |> assign(ephemeral_surfaces: Map.get(context, :ephemeral_surfaces, []))}
  end

  @impl true
  def render(%{node: %{children: []}} = assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-ephemeral-empty"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <h2 id={Base.component_title_id(@node)} class="sr-only">Ephemeral surfaces</h2>
    </section>
    """
  end

  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-ephemeral-shell"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <div>
        <h2 id={Base.component_title_id(@node)} class="workspace-pane-title">
          {Base.title(@node, "Ephemeral surface")}
        </h2>
        <p class="workspace-pane-subtitle">Task-scoped overlay</p>
      </div>
      <span class="allbert-chip">
        <.icon name="hero-bolt-micro" class="size-4" />
        {length(@ephemeral_surfaces)} active
      </span>
    </section>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Header do
  @moduledoc """
  Retained-but-unused `:header` implementation (operator decision, v0.61b
  M0/ADR 0080: the catalog atom stays registered).

  The appbar presentation this component rendered was retired at v0.61b M7 —
  its controls re-homed to the product sidebar, chat header, and pane header
  per the plan's relocation table. The old interior survived the retirement
  with dead event bindings (`toggle_thread_switcher` had no handler anywhere)
  and eight ids duplicating the live relocated controls, so M9.1 cut it to
  this inert stub: a tree that re-adds the `:header` atom renders a safe
  brand line — never a crash, a dead control, or a duplicate id.
  """
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :header,
    description: "Workspace header",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    {:ok, Base.assign_defaults(socket, assigns)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header
      id="workspace-retained-header"
      class="operator-view-header"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <div class="min-w-0">
        <h1 id={Base.component_title_id(@node)} class="operator-view-title">
          Allbert Assist
        </h1>
      </div>
    </header>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.BadgeStrip do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :badge_strip,
    description: "Status and objective badges",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> Base.assign_defaults(assigns)
     |> assign(
       active_objectives: Map.get(context, :active_objectives, []),
       workspace_badges: Map.get(context, :workspace_badges, [])
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class={["workspace-badge-strip", empty?(@active_objectives, @workspace_badges) && "hidden"]}
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <h2 id={Base.component_title_id(@node)} class="sr-only">Workspace status</h2>
      <span :for={objective <- @active_objectives} class="allbert-chip">
        <.icon name="hero-flag-micro" class="size-4" />
        {objective.status}: {objective.title}
      </span>
      <span :for={_badge <- @workspace_badges} class="allbert-chip allbert-chip-warn">
        <.icon name="hero-exclamation-triangle-micro" class="size-4" /> workspace notice
      </span>
    </section>
    """
  end

  defp empty?([], []), do: true
  defp empty?(_objectives, _badges), do: false
end

defmodule AllbertAssistWeb.Workspace.Components.Tabs do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tabs,
    description: "Workspace tabs",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"workspace-component-#{@node.id}"}
      class="workspace-tabs-label"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <span id={Base.component_title_id(@node)} class="sr-only">
        {Base.title(@node, "Workspace tabs")}
      </span>
    </div>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Tab do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tab,
    description: "Workspace tab",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    selected? = Base.prop(assigns.node, :selected?, false) == true
    panel_id = Base.prop(assigns.node, :panel_id, "workspace-tab-panel-#{assigns.node.id}")

    assigns =
      assign(assigns,
        selected?: selected?,
        panel_id: panel_id
      )

    ~H"""
    <button
      id={"workspace-component-#{@node.id}"}
      type="button"
      class="workspace-tab"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      role="tab"
      aria-selected={bool_attribute(@selected?)}
      aria-controls={@panel_id}
      tabindex={if @selected?, do: "0", else: "-1"}
    >
      {Base.title(@node, "Tab")}
    </button>
    """
  end

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"
end

defmodule AllbertAssistWeb.Workspace.Components.TabPanel do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tab_panel,
    description: "Workspace tab panel",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    hidden? = Base.prop(assigns.node, :hidden?, false) == true

    assigns = assign(assigns, hidden?: hidden?)

    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-tab-panel"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      role="tabpanel"
      hidden={@hidden?}
      aria-labelledby={Base.prop(@node, :tab_id, nil)}
    >
      <h2 class="sr-only">{Base.title(@node, "Tab panel")}</h2>
      <p :if={Base.present?(Base.summary(@node, ""))}>
        {Base.summary(@node, "")}
      </p>
    </section>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Diff do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :diff,
    description: "Diff viewer",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-diff"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <header class="workspace-card-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-code-bracket-square-micro" class="size-4" />
        </span>
        <h2 id={Base.component_title_id(@node)} class="workspace-card-title">
          {Base.title(@node, "Diff")}
        </h2>
      </header>
      <pre class="workspace-diff-body"><code>{Base.summary(@node, "")}</code></pre>
    </section>
    """
  end
end
