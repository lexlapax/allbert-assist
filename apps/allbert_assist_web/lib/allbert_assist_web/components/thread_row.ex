defmodule AllbertAssistWeb.Components.ThreadRow do
  @moduledoc """
  Shared conversation thread row (v0.61b M4).

  One row = switch button + inline-rename affordance. Built as a standalone
  function component so the row survives the M5 re-homing of the Conversations
  list from the workspace submenu column into the consolidated product sidebar
  unchanged. Events (`switch_workspace_thread`, `start_rename_thread`,
  `cancel_rename_thread`, `submit_rename_thread`) carry no `phx-target` and
  bubble to the hosting LiveView.

  Rename is inline per the v0.61b plan: hover/focus reveals the rename control,
  the label swaps to an input (`Enter` saves, `Escape` cancels, double-click on
  the title is a hook-backed accelerator); never a modal.
  """

  use Phoenix.Component

  import AllbertAssistWeb.CoreComponents, only: [icon: 1]

  alias Phoenix.LiveView.JS

  attr :thread, :map, required: true
  attr :active?, :boolean, default: false
  attr :renaming?, :boolean, default: false

  def thread_row(assigns) do
    ~H"""
    <div
      :if={@renaming?}
      id={"workspace-rail-thread-#{@thread.id}-rename"}
      class="workspace-rail-item workspace-rail-item-renaming"
      role="listitem"
    >
      <form
        class="workspace-rail-rename-form"
        phx-submit="submit_rename_thread"
        phx-value-thread-id={@thread.id}
      >
        <input type="hidden" name="thread-id" value={@thread.id} />
        <input
          type="text"
          name="title"
          value={@thread.title}
          maxlength="160"
          required
          aria-label={"Rename conversation #{@thread.title}"}
          class="workspace-rail-rename-input"
          phx-mounted={JS.focus()}
          phx-keydown="cancel_rename_thread"
          phx-key="escape"
        />
        <button
          type="submit"
          class="allbert-icon-button workspace-rail-rename-save"
          aria-label="Save conversation name"
          title="Save conversation name"
        >
          <.icon name="hero-check-micro" class="size-4" />
        </button>
        <button
          type="button"
          class="allbert-icon-button workspace-rail-rename-cancel"
          phx-click="cancel_rename_thread"
          aria-label="Cancel rename"
          title="Cancel rename"
        >
          <.icon name="hero-x-mark-micro" class="size-4" />
        </button>
      </form>
    </div>
    <div
      :if={not @renaming?}
      id={"workspace-rail-thread-#{@thread.id}-row"}
      class={[
        "workspace-rail-item workspace-rail-item-row",
        @active? && "workspace-rail-item-active"
      ]}
      role="listitem"
    >
      <button
        id={"workspace-rail-thread-#{@thread.id}"}
        type="button"
        class="workspace-rail-item-switch"
        phx-click="switch_workspace_thread"
        phx-value-thread-id={@thread.id}
        title={@thread.title}
      >
        <span
          id={"workspace-rail-thread-#{@thread.id}-title"}
          class="workspace-rail-item-title"
          phx-hook="ThreadRenameDblclick"
          data-thread-id={@thread.id}
        >
          {@thread.title}
        </span>
        <span class="workspace-rail-item-meta">{short_id(@thread.id)}</span>
      </button>
      <button
        id={"workspace-rail-thread-#{@thread.id}-rename-toggle"}
        type="button"
        class="allbert-icon-button workspace-rail-item-rename"
        phx-click="start_rename_thread"
        phx-value-thread-id={@thread.id}
        aria-label={"Rename conversation #{@thread.title}"}
        title={"Rename conversation #{@thread.title}"}
      >
        <.icon name="hero-pencil-square-micro" class="size-4" />
      </button>
    </div>
    """
  end

  defp short_id(nil), do: "conversation"

  defp short_id(id) when is_binary(id) do
    if String.length(id) > 14, do: String.slice(id, 0, 10) <> "...", else: id
  end
end
