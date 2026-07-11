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
    :mcp_effect_form,
    :status_badge,
    :skeleton_placeholder,
    :workspace_shell,
    :nav_rail,
    :thread_list,
    :app_launcher,
    :utility_drawer,
    :workspace_panel,
    :onboarding_panel,
    :intents_panel,
    :models_panel,
    :channels_panel,
    :surface_policy_panel,
    :settings_panel,
    :template_create_panel,
    :plan_preview_panel,
    :plan_run_progress_panel,
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
    :notes_files_panel,
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
    :mcp_effect_form,
    :status_badge,
    :skeleton_placeholder,
    :workspace_shell,
    :nav_rail,
    :thread_list,
    :app_launcher,
    :utility_drawer,
    :workspace_panel,
    :onboarding_panel,
    :intents_panel,
    :models_panel,
    :channels_panel,
    :surface_policy_panel,
    :settings_panel,
    :template_create_panel,
    :plan_preview_panel,
    :plan_run_progress_panel,
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
    mcp_effect_form: {:live_component, AllbertAssistWeb.Workspace.Components.McpEffectForm},
    status_badge: {:live_component, AllbertAssistWeb.Workspace.Components.StatusBadge},
    skeleton_placeholder:
      {:live_component, AllbertAssistWeb.Workspace.Components.SkeletonPlaceholder},
    workspace_shell: {:live_component, AllbertAssistWeb.Workspace.Components.WorkspaceShell},
    nav_rail: {:live_component, AllbertAssistWeb.Workspace.Components.NavRail},
    thread_list: {:live_component, AllbertAssistWeb.Workspace.Components.ThreadList},
    app_launcher: {:live_component, AllbertAssistWeb.Workspace.Components.AppLauncher},
    utility_drawer: {:live_component, AllbertAssistWeb.Workspace.Components.UtilityDrawer},
    workspace_panel: {:live_component, AllbertAssistWeb.Workspace.Components.WorkspacePanel},
    onboarding_panel: {:live_component, AllbertAssistWeb.Workspace.Components.Onboarding},
    intents_panel: {:live_component, AllbertAssistWeb.Workspace.Components.IntentsPanel},
    models_panel: {:live_component, AllbertAssistWeb.Workspace.Components.ModelsPanel},
    channels_panel: {:live_component, AllbertAssistWeb.Workspace.Components.ChannelsPanel},
    surface_policy_panel:
      {:live_component, AllbertAssistWeb.Workspace.Components.SurfacePolicyPanel},
    settings_panel: {:live_component, AllbertAssistWeb.Workspace.Components.SettingsCentral},
    template_create_panel:
      {:live_component, AllbertAssistWeb.Workspace.Components.TemplateCreate},
    plan_preview_panel: {:live_component, AllbertAssistWeb.Workspace.Components.PlanPreviewPanel},
    plan_run_progress_panel:
      {:live_component, AllbertAssistWeb.Workspace.Components.PlanRunProgressPanel},
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
    notes_files_panel: {:live_component, AllbertAssistWeb.Workspace.Components.NotesPanel},
    # v0.65 M4: the memory-review component renders the interactive
    # `workspace:memory` review panel (keep/reject/delete through the Runner),
    # replacing the earlier unwired placeholder card.
    memory_review_card: {:live_component, AllbertAssistWeb.Workspace.Components.MemoryPanel},
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
    notes_files_panel: "hero-document-text-micro",
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
    mcp_effect_form: "hero-pencil-square-micro",
    status_badge: "hero-signal-micro",
    skeleton_placeholder: "hero-cube-transparent-micro",
    workspace_shell: "hero-window-micro",
    nav_rail: "hero-bars-3-bottom-left-micro",
    thread_list: "hero-chat-bubble-left-right-micro",
    app_launcher: "hero-squares-2x2-micro",
    utility_drawer: "hero-wrench-screwdriver-micro",
    workspace_panel: "hero-rectangle-group-micro",
    onboarding_panel: "hero-sparkles-micro",
    intents_panel: "hero-bolt-micro",
    models_panel: "hero-cpu-chip-micro",
    surface_policy_panel: "hero-shield-check-micro",
    settings_panel: "hero-adjustments-horizontal-micro",
    template_create_panel: "hero-plus-circle-micro",
    plan_preview_panel: "hero-clipboard-document-list-micro",
    plan_run_progress_panel: "hero-list-bullet-micro"
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
