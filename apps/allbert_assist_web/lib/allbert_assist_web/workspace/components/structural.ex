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
    description: "Canvas tile"
end

defmodule AllbertAssistWeb.Workspace.Components.EphemeralSurface do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :ephemeral_surface,
    description: "Shared ephemeral surface"
end

defmodule AllbertAssistWeb.Workspace.Components.Header do
  @moduledoc "Workspace renderer for the `:header` catalog component."

  use AllbertAssistWeb, :live_component

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
