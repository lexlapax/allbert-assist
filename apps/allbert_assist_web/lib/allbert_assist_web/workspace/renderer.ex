defmodule AllbertAssistWeb.Workspace.Renderer do
  @moduledoc """
  Dispatches declarative workspace Surface nodes to web components.

  The core catalog stays web-agnostic. M4 wires the dispatcher and keeps most
  components on a placeholder renderer; later milestones replace those
  placeholders with concrete component modules.
  """

  use AllbertAssistWeb, :live_component

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias AllbertAssistWeb.Workspace.Components.ActionButton
  alias AllbertAssistWeb.Workspace.Components.AgentReportCard
  alias AllbertAssistWeb.Workspace.Components.AnalysisCard
  alias AllbertAssistWeb.Workspace.Components.ApprovalCard
  alias AllbertAssistWeb.Workspace.Components.ApprovalInspector
  alias AllbertAssistWeb.Workspace.Components.BadgeStrip
  alias AllbertAssistWeb.Workspace.Components.Button
  alias AllbertAssistWeb.Workspace.Components.Canvas
  alias AllbertAssistWeb.Workspace.Components.ChannelCard
  alias AllbertAssistWeb.Workspace.Components.Chat
  alias AllbertAssistWeb.Workspace.Components.Column
  alias AllbertAssistWeb.Workspace.Components.Composer
  alias AllbertAssistWeb.Workspace.Components.ConfirmationCard
  alias AllbertAssistWeb.Workspace.Components.DebateRoundCard
  alias AllbertAssistWeb.Workspace.Components.Diff
  alias AllbertAssistWeb.Workspace.Components.Divider
  alias AllbertAssistWeb.Workspace.Components.EmptyState
  alias AllbertAssistWeb.Workspace.Components.EphemeralSurface
  alias AllbertAssistWeb.Workspace.Components.Header
  alias AllbertAssistWeb.Workspace.Components.Icon
  alias AllbertAssistWeb.Workspace.Components.JobCard
  alias AllbertAssistWeb.Workspace.Components.Link
  alias AllbertAssistWeb.Workspace.Components.List
  alias AllbertAssistWeb.Workspace.Components.MemoryReviewCard
  alias AllbertAssistWeb.Workspace.Components.ObjectiveCard
  alias AllbertAssistWeb.Workspace.Components.Panel
  alias AllbertAssistWeb.Workspace.Components.ParityCard
  alias AllbertAssistWeb.Workspace.Components.Placeholder
  alias AllbertAssistWeb.Workspace.Components.Route
  alias AllbertAssistWeb.Workspace.Components.Row
  alias AllbertAssistWeb.Workspace.Components.Section
  alias AllbertAssistWeb.Workspace.Components.SettingsCard
  alias AllbertAssistWeb.Workspace.Components.StatusBadge
  alias AllbertAssistWeb.Workspace.Components.Tab
  alias AllbertAssistWeb.Workspace.Components.Table
  alias AllbertAssistWeb.Workspace.Components.TabPanel
  alias AllbertAssistWeb.Workspace.Components.Tabs
  alias AllbertAssistWeb.Workspace.Components.Text
  alias AllbertAssistWeb.Workspace.Components.Tile
  alias AllbertAssistWeb.Workspace.Components.Timeline
  alias AllbertAssistWeb.Workspace.Components.TraceLink
  alias AllbertAssistWeb.Workspace.Components.TraceViewer
  alias AllbertAssistWeb.Workspace.Components.Workspace

  @component_modules %{
    route: Route,
    chat: Chat,
    timeline: Timeline,
    composer: Composer,
    panel: Panel,
    section: Section,
    text: Text,
    list: List,
    empty_state: EmptyState,
    button: Button,
    action_button: ActionButton,
    status_badge: StatusBadge,
    workspace: Workspace,
    canvas: Canvas,
    tile: Tile,
    ephemeral_surface: EphemeralSurface,
    header: Header,
    badge_strip: BadgeStrip,
    tabs: Tabs,
    tab: Tab,
    tab_panel: TabPanel,
    diff: Diff,
    trace_link: TraceLink,
    trace_viewer: TraceViewer,
    icon: Icon,
    link: Link,
    divider: Divider,
    table: Table,
    row: Row,
    column: Column,
    objective_card: ObjectiveCard,
    confirmation_card: ConfirmationCard,
    approval_card: ApprovalCard,
    approval_inspector: ApprovalInspector,
    memory_review_card: MemoryReviewCard,
    job_card: JobCard,
    channel_card: ChannelCard,
    settings_card: SettingsCard,
    analysis_card: AnalysisCard,
    agent_report_card: AgentReportCard,
    parity_card: ParityCard,
    debate_round_card: DebateRoundCard
  }

  def renderer_for(component) when is_atom(component) do
    Map.get(@component_modules, component, Placeholder)
  end

  def renderer_for(_component), do: Placeholder

  @impl true
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)
     |> assign_new(:renderer_context, fn -> %{} end)
     |> assign_new(:workspace_state, fn -> %{} end)}
  end

  @impl true
  def render(%{surface: %Surface{}} = assigns) do
    ~H"""
    <div
      id={@id}
      class="workspace-renderer space-y-4"
      data-workspace-renderer="surface"
      data-workspace-surface={@surface.id}
    >
      <.live_component
        :for={node <- @surface.nodes}
        module={__MODULE__}
        id={node_renderer_id(@id, node)}
        node={node}
        renderer_context={@renderer_context}
        workspace_state={@workspace_state}
      />
    </div>
    """
  end

  def render(%{node: %Node{}} = assigns) do
    ~H"""
    <div
      id={"workspace-node-#{@node.id}"}
      class="workspace-node space-y-4"
      data-workspace-component={@node.component}
      data-workspace-node={@node.id}
    >
      <.live_component
        module={renderer_for(@node.component)}
        id={node_component_id(@id, @node)}
        node={@node}
        renderer_context={@renderer_context}
        workspace_state={@workspace_state}
      />

      <div :if={@node.children != []} class="workspace-node-children space-y-4">
        <.live_component
          :for={child <- @node.children}
          module={__MODULE__}
          id={node_renderer_id(@id, child)}
          node={child}
          renderer_context={@renderer_context}
          workspace_state={@workspace_state}
        />
      </div>
    </div>
    """
  end

  defp node_renderer_id(parent_id, %Node{id: node_id}), do: "#{parent_id}:#{node_id}:renderer"
  defp node_component_id(parent_id, %Node{id: node_id}), do: "#{parent_id}:#{node_id}:component"
end
