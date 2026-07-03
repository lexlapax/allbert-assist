defmodule AllbertAssistWeb.Components.WorkspaceSections do
  @moduledoc """
  Contextual workspace sections nested under the product sidebar's Workspace
  entry (v0.61b M5, ADR 0080 §1) — the consolidated home of what the retired
  workspace-local submenu column (NavRail/ThreadList/AppLauncher) carried:
  Conversations (thread rows + new conversation), then the Output/Apps/
  Workspace destination sections.

  Rendered ONLY when the hosting LiveView passes the workspace context
  (`/workspace`); operator shells pass none, so no workspace phx-click control
  can reach a LiveView without handlers (the guarded-controls rule). Events
  (`new_thread`, `switch_workspace_thread`, `select_destination`, the rename
  events via `ThreadRow`) carry no `phx-target` and bubble to `WorkspaceLive`.
  Destination rows keep the `workspace-dest-*` DOM ids and
  `select_destination` dispatch the retired AppLauncher used, so deep links
  and in-place destination switching behave identically.
  """

  use Phoenix.Component

  import AllbertAssistWeb.Components.ThreadRow, only: [thread_row: 1]
  import AllbertAssistWeb.CoreComponents, only: [icon: 1]

  attr :workspace, :map, required: true

  def workspace_sections(assigns) do
    ~H"""
    <div
      id="sidebar-workspace-sections"
      class="operator-workspace-sections"
      role="group"
      aria-label="Workspace sections"
    >
      <div class="workspace-sidebar-section">
        <div class="workspace-sidebar-section-head">
          <h3 class="workspace-rail-section-title">Conversations</h3>
          <button
            id="workspace-launcher"
            type="button"
            class="allbert-icon-button"
            phx-click="new_thread"
            aria-label="New conversation"
            title="New conversation"
          >
            <.icon name="hero-plus-micro" class="size-4" />
          </button>
        </div>
        <div class="workspace-rail-list workspace-sidebar-conversations" role="list">
          <.thread_row
            :for={thread <- Map.get(@workspace, :recent_threads, [])}
            thread={thread}
            active?={thread.id == Map.get(@workspace, :thread_id)}
            renaming?={thread.id == Map.get(@workspace, :renaming_thread_id)}
          />
          <p
            :if={Map.get(@workspace, :recent_threads, []) == []}
            class="workspace-rail-empty"
          >
            No conversations yet.
          </p>
        </div>
      </div>
      <div
        :for={{section, destinations} <- sections(Map.get(@workspace, :destinations, []))}
        class="workspace-sidebar-section"
      >
        <h3 class="workspace-rail-section-title workspace-rail-section-spaced">
          {section_label(section)}
        </h3>
        <%!-- v0.61b M9.2: no list/listitem roles here — role="listitem" on a
        <button> strips its button semantics and makes aria-pressed invalid;
        these are toggle buttons in a headed group. --%>
        <div class="workspace-rail-list">
          <button
            :for={destination <- destinations}
            id={"workspace-dest-#{destination.dom_id}"}
            type="button"
            class={[
              "workspace-rail-item workspace-destination-item",
              destination.section == :apps && "workspace-app-launcher-item",
              destination.id == Map.get(@workspace, :canvas_destination) &&
                "workspace-rail-item-active"
            ]}
            phx-click="select_destination"
            phx-value-destination={destination.id}
            data-destination={destination.id}
            data-app-id={Map.get(destination, :app_id)}
            aria-pressed={bool_attribute(destination.id == Map.get(@workspace, :canvas_destination))}
            title={destination.label}
          >
            <span class="workspace-app-icon" aria-hidden="true">
              <.icon name={destination_icon(destination)} class="size-4" />
            </span>
            <span class="workspace-rail-item-title">{destination.label}</span>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp sections(destinations) do
    destinations
    |> Enum.chunk_by(& &1.section)
    |> Enum.map(fn entries -> {hd(entries).section, entries} end)
  end

  defp section_label(:output), do: "Output"
  defp section_label(:apps), do: "Apps"
  defp section_label(:workspace), do: "Workspace"
  defp section_label(other), do: other |> to_string() |> String.capitalize()

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
