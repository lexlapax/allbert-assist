# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.Route do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :route,
    description: "Registered navigation route",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <span
      id={"workspace-component-#{@node.id}"}
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      hidden
    />
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Timeline do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :timeline,
    description: "Runtime timeline subregion",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"workspace-component-#{@node.id}"}
      class="workspace-chat-subregion"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-hidden="true"
      hidden
    />
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Composer do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :composer,
    description: "Prompt entry subregion",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"workspace-component-#{@node.id}"}
      class="workspace-chat-subregion"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-hidden="true"
      hidden
    />
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Panel do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :panel,
    description: "Workspace panel"
end

defmodule AllbertAssistWeb.Workspace.Components.Section do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :section,
    description: "Workspace section"
end

defmodule AllbertAssistWeb.Workspace.Components.Text do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :text,
    description: "Text block"
end

defmodule AllbertAssistWeb.Workspace.Components.List do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :list,
    description: "List"
end

defmodule AllbertAssistWeb.Workspace.Components.EmptyState do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :empty_state,
    description: "Empty state",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-empty-state"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <span class="workspace-empty-state-icon" aria-hidden="true">
        <.icon name="hero-sparkles-mini" class="size-5" />
      </span>
      <div>
        <h2 id={Base.component_title_id(@node)} class="workspace-card-title">
          {Base.title(@node, "Nothing here yet")}
        </h2>
        <p class="workspace-card-summary">
          {Base.summary(@node, "Allbert's work appears here as runtime fragments land.")}
        </p>
      </div>
    </section>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Button do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :button,
    description: "Button",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <button
      id={Base.dom_id(@node)}
      type="button"
      class="workspace-button workspace-button-secondary"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-intent-option={intent_option(@node)}
      phx-click={Base.prop(@node, :phx_click, nil)}
      phx-value-surface-id={Base.prop(@node, :surface_id, nil)}
      phx-value-app-id={Base.prop(@node, :app_id, nil)}
      phx-value-action-name={Base.prop(@node, :action_name, nil)}
      phx-value-destination={Base.prop(@node, :destination, nil)}
      phx-value-source-text={Base.prop(@node, :source_text, nil)}
      phx-value-candidate-id={Base.prop(@node, :candidate_id, nil)}
      phx-value-server-id={Base.prop(@node, :server_id, nil)}
      phx-value-resource-uri={Base.prop(@node, :resource_uri, nil)}
      phx-value-tool-name={Base.prop(@node, :tool_name, nil)}
      phx-value-integration={Base.prop(@node, :integration, nil)}
      phx-value-integration-action={Base.prop(@node, :integration_action, nil)}
      phx-value-ticker={Base.prop(@node, :ticker, nil)}
    >
      {Base.title(@node, "Button")}
    </button>
    """
  end

  defp intent_option(node) do
    if Base.prop(node, :intent_option?, false), do: "true"
  end
end

defmodule AllbertAssistWeb.Workspace.Components.ActionButton do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :action_button,
    description: "Action button",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <button
      id={Base.dom_id(@node)}
      type="button"
      class="workspace-button workspace-button-primary"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      phx-click={Base.prop(@node, :phx_click, nil)}
      phx-value-surface-id={Base.prop(@node, :surface_id, nil)}
      phx-value-app-id={Base.prop(@node, :app_id, nil)}
      phx-value-action-name={Base.prop(@node, :action_name, nil)}
      phx-value-destination={Base.prop(@node, :destination, nil)}
      phx-value-source-text={Base.prop(@node, :source_text, nil)}
      phx-value-candidate-id={Base.prop(@node, :candidate_id, nil)}
      phx-value-server-id={Base.prop(@node, :server_id, nil)}
      phx-value-resource-uri={Base.prop(@node, :resource_uri, nil)}
      phx-value-tool-name={Base.prop(@node, :tool_name, nil)}
      phx-value-integration={Base.prop(@node, :integration, nil)}
      phx-value-integration-action={Base.prop(@node, :integration_action, nil)}
      phx-value-ticker={Base.prop(@node, :ticker, nil)}
    >
      <.icon name="hero-bolt-micro" class="size-4" />
      {Base.title(@node, "Action")}
    </button>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.StatusBadge do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :status_badge,
    description: "Status badge",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <span
      id={"workspace-component-#{@node.id}"}
      class={["workspace-status-pill", status_class(Base.prop(@node, :status, "info"))]}
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
    >
      {Base.summary(@node, Base.title(@node, "Status"))}
    </span>
    """
  end

  defp status_class(status) when status in ["warn", :warn, "warning", :warning],
    do: "workspace-status-warn"

  defp status_class(status) when status in ["danger", :danger, "error", :error],
    do: "workspace-status-danger"

  defp status_class(status) when status in ["success", :success, "ok", :ok],
    do: "workspace-status-success"

  defp status_class(_status), do: "workspace-status-neutral"
end
