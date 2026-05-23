defmodule AllbertAssist.Surface.Catalog do
  @moduledoc """
  Shared Surface component catalog and renderer registration facade.

  This is descriptive metadata. Component membership or renderer registration
  never grants action permission, app scope, route authority, or dynamic module
  loading.
  """

  @known_components [
    :route,
    :chat,
    :timeline,
    :composer,
    :panel,
    :section,
    :text,
    :list,
    :empty_state,
    :button,
    :action_button,
    :status_badge,
    :workspace,
    :canvas,
    :tile,
    :ephemeral_surface,
    :header,
    :badge_strip,
    :tabs,
    :tab,
    :tab_panel,
    :diff,
    :trace_link,
    :trace_viewer,
    :icon,
    :link,
    :divider,
    :table,
    :row,
    :column,
    :objective_card,
    :confirmation_card,
    :approval_card,
    :approval_inspector,
    :memory_review_card,
    :job_card,
    :channel_card,
    :settings_card,
    :analysis_card,
    :agent_report_card,
    :parity_card,
    :debate_round_card
  ]

  @known_zones [
    :nav_apps,
    :context_rail,
    :canvas_panels,
    :utility_drawer,
    :ephemeral
  ]

  @primitive_components [
    :route,
    :chat,
    :timeline,
    :composer,
    :panel,
    :section,
    :text,
    :list,
    :empty_state,
    :button,
    :action_button,
    :status_badge,
    :workspace,
    :canvas,
    :tile,
    :ephemeral_surface,
    :header,
    :badge_strip,
    :tabs,
    :tab,
    :tab_panel,
    :diff,
    :trace_link,
    :trace_viewer,
    :icon,
    :link,
    :divider,
    :table,
    :row,
    :column
  ]

  @renderer_descriptors %{
    route: {:live_component, AllbertAssistWeb.Workspace.Components.Route},
    chat: {:live_component, AllbertAssistWeb.Workspace.Components.Chat},
    timeline: {:live_component, AllbertAssistWeb.Workspace.Components.Timeline},
    composer: {:live_component, AllbertAssistWeb.Workspace.Components.Composer},
    panel: {:live_component, AllbertAssistWeb.Workspace.Components.Panel},
    section: {:live_component, AllbertAssistWeb.Workspace.Components.Section},
    text: {:live_component, AllbertAssistWeb.Workspace.Components.Text},
    list: {:live_component, AllbertAssistWeb.Workspace.Components.List},
    empty_state: {:live_component, AllbertAssistWeb.Workspace.Components.EmptyState},
    button: {:live_component, AllbertAssistWeb.Workspace.Components.Button},
    action_button: {:live_component, AllbertAssistWeb.Workspace.Components.ActionButton},
    status_badge: {:live_component, AllbertAssistWeb.Workspace.Components.StatusBadge},
    workspace: {:live_component, AllbertAssistWeb.Workspace.Components.Workspace},
    canvas: {:live_component, AllbertAssistWeb.Workspace.Components.Canvas},
    tile: {:live_component, AllbertAssistWeb.Workspace.Components.Tile},
    ephemeral_surface: {:live_component, AllbertAssistWeb.Workspace.Components.EphemeralSurface},
    header: {:live_component, AllbertAssistWeb.Workspace.Components.Header},
    badge_strip: {:live_component, AllbertAssistWeb.Workspace.Components.BadgeStrip},
    tabs: {:live_component, AllbertAssistWeb.Workspace.Components.Tabs},
    tab: {:live_component, AllbertAssistWeb.Workspace.Components.Tab},
    tab_panel: {:live_component, AllbertAssistWeb.Workspace.Components.TabPanel},
    diff: {:live_component, AllbertAssistWeb.Workspace.Components.Diff},
    trace_link: {:live_component, AllbertAssistWeb.Workspace.Components.TraceLink},
    trace_viewer: {:live_component, AllbertAssistWeb.Workspace.Components.TraceViewer},
    icon: {:live_component, AllbertAssistWeb.Workspace.Components.Icon},
    link: {:live_component, AllbertAssistWeb.Workspace.Components.Link},
    divider: {:live_component, AllbertAssistWeb.Workspace.Components.Divider},
    table: {:live_component, AllbertAssistWeb.Workspace.Components.Table},
    row: {:live_component, AllbertAssistWeb.Workspace.Components.Row},
    column: {:live_component, AllbertAssistWeb.Workspace.Components.Column},
    objective_card: {:live_component, AllbertAssistWeb.Workspace.Components.ObjectiveCard},
    confirmation_card: {:live_component, AllbertAssistWeb.Workspace.Components.ConfirmationCard},
    approval_card: {:live_component, AllbertAssistWeb.Workspace.Components.ApprovalCard},
    approval_inspector:
      {:live_component, AllbertAssistWeb.Workspace.Components.ApprovalInspector},
    memory_review_card: {:live_component, AllbertAssistWeb.Workspace.Components.MemoryReviewCard},
    job_card: {:live_component, AllbertAssistWeb.Workspace.Components.JobCard},
    channel_card: {:live_component, AllbertAssistWeb.Workspace.Components.ChannelCard},
    settings_card: {:live_component, AllbertAssistWeb.Workspace.Components.SettingsCard},
    analysis_card: {:function_component, StockSageWeb.Components.Cards, :analysis_card},
    agent_report_card: {:function_component, StockSageWeb.Components.Cards, :agent_report_card},
    parity_card: {:function_component, StockSageWeb.Components.Cards, :parity_card},
    debate_round_card: {:function_component, StockSageWeb.Components.Cards, :debate_round_card}
  }

  @component_icons %{
    trace_link: "hero-link-micro",
    trace_viewer: "hero-document-text-micro",
    objective_card: "hero-flag-micro",
    confirmation_card: "hero-shield-check-micro",
    approval_card: "hero-check-circle-micro",
    approval_inspector: "hero-magnifying-glass-micro",
    memory_review_card: "hero-book-open-micro",
    job_card: "hero-clock-micro",
    channel_card: "hero-inbox-micro",
    settings_card: "hero-adjustments-horizontal-micro",
    analysis_card: "hero-chart-bar-micro",
    agent_report_card: "hero-document-chart-bar-micro",
    parity_card: "hero-scale-micro",
    debate_round_card: "hero-chat-bubble-left-right-micro",
    button: "hero-play-micro",
    action_button: "hero-bolt-micro",
    status_badge: "hero-signal-micro"
  }

  @placeholder_renderer {:live_component, AllbertAssistWeb.Workspace.Components.Placeholder}
  @default_icon "hero-squares-2x2-micro"

  @type zone :: :nav_apps | :context_rail | :canvas_panels | :utility_drawer | :ephemeral

  @type renderer_descriptor ::
          {:live_component, module()}
          | {:function_component, module(), atom()}

  @spec known_components() :: [atom(), ...]
  def known_components, do: @known_components

  @spec known_zones() :: [zone(), ...]
  def known_zones, do: @known_zones

  @spec primitive_components() :: [atom(), ...]
  def primitive_components, do: @primitive_components

  @spec known_component?(term()) :: boolean()
  def known_component?(component), do: component in @known_components

  @spec known_zone?(term()) :: boolean()
  def known_zone?(zone), do: zone in @known_zones

  @spec primitive_component?(term()) :: boolean()
  def primitive_component?(component), do: component in @primitive_components

  @spec app_component?(term()) :: boolean()
  def app_component?(component),
    do: known_component?(component) and not primitive_component?(component)

  @spec renderer_for(term()) :: renderer_descriptor()
  def renderer_for(component) when is_atom(component) do
    Map.get(@renderer_descriptors, component, @placeholder_renderer)
  end

  def renderer_for(_component), do: @placeholder_renderer

  @spec renderer_module(term()) :: module()
  def renderer_module(component) do
    case renderer_for(component) do
      {:live_component, module} -> module
      {:function_component, module, _function} -> module
    end
  end

  def renderer_components, do: @renderer_descriptors

  @spec icon_for(term()) :: String.t()
  def icon_for(component) when is_atom(component),
    do: Map.get(@component_icons, component, @default_icon)

  def icon_for(_component), do: @default_icon
end
