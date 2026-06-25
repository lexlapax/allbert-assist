# credo:disable-for-this-file Credo.Check.Readability.ModuleDoc
# Component docs are injected by AllbertAssistWeb.Workspace.Components.Base.

defmodule AllbertAssistWeb.Workspace.Components.TraceLink do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :trace_link,
    description: "Trace link",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <a
      id={"workspace-component-#{@node.id}"}
      class="workspace-trace-link"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      href={Base.prop(@node, :href, "#")}
    >
      <.icon name="hero-link-micro" class="size-4" />
      <span class="workspace-mono">{Base.summary(@node, Base.title(@node, "trace"))}</span>
    </a>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.TraceViewer do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :trace_viewer,
    description: "Trace viewer",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-trace-viewer"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <header class="workspace-card-header">
        <span class="workspace-card-icon" aria-hidden="true">
          <.icon name="hero-document-text-micro" class="size-4" />
        </span>
        <h2 id={Base.component_title_id(@node)} class="workspace-card-title">
          {Base.title(@node, "Trace")}
        </h2>
      </header>
      <pre class="workspace-trace-body">{Base.summary(@node, "")}</pre>
    </section>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Icon do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :icon,
    description: "Icon",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <span
      id={"workspace-component-#{@node.id}"}
      class="workspace-inline-icon"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-label={Base.prop(@node, :label, nil)}
    >
      <.icon name={Base.prop(@node, :name, "hero-squares-2x2-micro")} class="size-4" />
    </span>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Link do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :link,
    description: "Link",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <a
      id={"workspace-component-#{@node.id}"}
      class="workspace-link"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      href={Base.prop(@node, :href, Base.summary(@node, "#"))}
    >
      {Base.title(@node, "Open")}
    </a>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Divider do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :divider,
    description: "Divider",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <hr
      id={"workspace-component-#{@node.id}"}
      class="workspace-divider"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      aria-label={Base.prop(@node, :label, nil)}
    />
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Table do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :table,
    description: "Table",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <section
      id={"workspace-component-#{@node.id}"}
      class="workspace-table-shell"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-workspace-pattern="table-list"
      aria-labelledby={Base.component_title_id(@node)}
    >
      <h2 id={Base.component_title_id(@node)} class="workspace-card-title">
        {Base.title(@node, "Table")}
      </h2>
      <div class="workspace-table-empty">{Base.summary(@node, "Rows appear here.")}</div>
    </section>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Row do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :row,
    description: "Table row",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id={"workspace-component-#{@node.id}"}
      class="workspace-table-row"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-workspace-pattern="table-row"
    >
      {Base.summary(@node, Base.title(@node, "Row"))}
    </div>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.Column do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :column,
    description: "Table column",
    custom?: true

  alias AllbertAssistWeb.Workspace.Components.Base

  @impl true
  def update(assigns, socket), do: {:ok, Base.assign_defaults(socket, assigns)}

  @impl true
  def render(assigns) do
    ~H"""
    <span
      id={"workspace-component-#{@node.id}"}
      class="workspace-table-column"
      data-workspace-component={@node.component}
      data-workspace-renderer="component"
      data-workspace-pattern="table-column"
    >
      {Base.summary(@node, Base.title(@node, "Column"))}
    </span>
    """
  end
end

defmodule AllbertAssistWeb.Workspace.Components.ObjectiveCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :objective_card,
    description: "Objective summary card"
end

defmodule AllbertAssistWeb.Workspace.Components.ConfirmationCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :confirmation_card,
    description: "Confirmation summary card"
end

defmodule AllbertAssistWeb.Workspace.Components.ApprovalCard do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :approval_card,
    description: "Approval summary card"
end

defmodule AllbertAssistWeb.Workspace.Components.ApprovalInspector do
  use AllbertAssistWeb.Workspace.Components.Base,
    component: :approval_inspector,
    description: "Approval details inspector"
end
