# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.Workspace do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :workspace,
    description: "Workspace shell"
end

defmodule AllbertAssistWeb.Workspace.Components.Canvas do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :canvas,
    description: "Persistent per-thread canvas"
end

defmodule AllbertAssistWeb.Workspace.Components.Tile do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tile,
    description: "Editable and read-only canvas tile",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

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
       indexeddb_quota_bytes: Map.get(context, :workspace_indexeddb_quota_bytes, 33_554_432)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="rounded border border-base-300 bg-base-100 p-3 text-sm"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-workspace-tile-id={Base.prop(@node, :tile_id, nil)}
      aria-labelledby={Base.component_title_id(@node)}
    >
      <div class="flex items-start justify-between gap-3">
        <div class="min-w-0">
          <h2 id={Base.component_title_id(@node)} class="text-sm font-semibold leading-6">
            {Base.title(@node, "Canvas tile")}
          </h2>
          <p class="text-xs text-base-content/60">
            {tile_kind_label(@node)}
          </p>
        </div>
      </div>

      <div
        :if={editable?(@node, @offline_enabled?)}
        id={editor_id(@node)}
        class="workspace-tile-editor mt-3"
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

      <pre :if={!editable?(@node, @offline_enabled?)} class="mt-3 whitespace-pre-wrap text-xs">
    {Base.summary(@node, "Canvas tile")}
      </pre>

      <div
        :if={conflict?(@node)}
        class="workspace-conflict-banner mt-3"
        data-workspace-conflict-banner="true"
        role="status"
      >
        <p>
          Conflict reconciled. {conflict_count(@node)} offline edit(s) were merged into this
          tile.
        </p>
        <button
          :if={revert_revision_id(@node)}
          type="button"
          class="btn btn-xs btn-outline mt-2"
          phx-click="revert_tile_revision"
          phx-value-tile-id={Base.prop(@node, :tile_id, "")}
          phx-value-revision-id={revert_revision_id(@node)}
        >
          Revert
        </button>
      </div>
    </section>
    """
  end

  defp editable?(node, true), do: Base.prop(node, :editable?, false) == true
  defp editable?(_node, false), do: false

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
    description: "Shared ephemeral surface"
end

defmodule AllbertAssistWeb.Workspace.Components.Header do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :header,
    description: "Workspace header",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket) do
    context = Map.get(assigns, :renderer_context, %{})

    {:ok,
     socket
     |> Base.assign_defaults(assigns)
     |> assign(
       workspace_theme: Map.get(context, :workspace_theme, "system"),
       workspace_high_contrast?: Map.get(context, :workspace_high_contrast?, false)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <header
      id={"workspace-component-#{@node.id}"}
      class="workspace-header flex items-start justify-between gap-3 rounded border border-base-300 bg-base-100 p-3 text-sm"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <div class="min-w-0">
        <h2 id={Base.component_title_id(@node)} class="text-sm font-semibold leading-6">
          {Base.prop(@node, :title, "Allbert Workspace")}
        </h2>
        <p class="text-xs text-base-content/60">
          {Base.prop(@node, :subtitle, "Runtime chat, canvas, and ephemeral surfaces.")}
        </p>
      </div>

      <button
        id="workspace-theme-toggle"
        type="button"
        class="workspace-theme-toggle btn btn-sm btn-circle shrink-0"
        phx-click="toggle_workspace_theme"
        aria-label={theme_toggle_label(@workspace_theme)}
        title={theme_toggle_label(@workspace_theme)}
        data-current-theme={@workspace_theme}
        data-next-theme={next_workspace_theme(@workspace_theme)}
        data-high-contrast={bool_attribute(@workspace_high_contrast?)}
      >
        <.icon name={theme_toggle_icon(@workspace_theme)} class="size-4" />
        <span class="sr-only">{theme_toggle_label(@workspace_theme)}</span>
      </button>
    </header>
    """
  end

  defp next_workspace_theme("dark"), do: "light"
  defp next_workspace_theme(_theme), do: "dark"

  defp theme_toggle_icon("dark"), do: "hero-sun-micro"
  defp theme_toggle_icon(_theme), do: "hero-moon-micro"

  defp theme_toggle_label("dark"), do: "Switch workspace theme to light"
  defp theme_toggle_label(_theme), do: "Switch workspace theme to dark"

  defp bool_attribute(true), do: "true"
  defp bool_attribute(false), do: "false"
end

defmodule AllbertAssistWeb.Workspace.Components.BadgeStrip do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :badge_strip,
    description: "Status and objective badges"
end

defmodule AllbertAssistWeb.Workspace.Components.Tabs do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tabs,
    description: "Workspace tabs"
end

defmodule AllbertAssistWeb.Workspace.Components.Tab do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tab,
    description: "Workspace tab"
end

defmodule AllbertAssistWeb.Workspace.Components.TabPanel do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :tab_panel,
    description: "Workspace tab panel"
end

defmodule AllbertAssistWeb.Workspace.Components.Diff do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :diff,
    description: "Diff viewer"
end
