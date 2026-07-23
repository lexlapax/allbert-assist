defmodule AllbertAssist.Actions.Registry do
  @moduledoc """
  Canonical registry for Allbert runtime-facing Jido actions.

  Pure domain modules can remain plain Elixir behind these actions. Runtime
  callers should resolve action names or modules through this registry before
  invoking work.
  """

  alias AllbertAssist.Action

  alias AllbertAssist.Actions.Apps.ListApps
  alias AllbertAssist.Actions.Apps.ShowApp
  alias AllbertAssist.Actions.Artifacts.ArtifactDoctor
  alias AllbertAssist.Actions.Artifacts.ArtifactThreads
  alias AllbertAssist.Actions.Artifacts.DeleteArtifact
  alias AllbertAssist.Actions.Artifacts.GetArtifact
  alias AllbertAssist.Actions.Artifacts.ListArtifacts
  alias AllbertAssist.Actions.Artifacts.PutArtifact
  alias AllbertAssist.Actions.Calendar.CreateCalendarEvent
  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Channels.ConfigureChannelSecret
  alias AllbertAssist.Actions.Channels.ConfigureChannelSetting
  alias AllbertAssist.Actions.Channels.LinkChannelIdentity
  alias AllbertAssist.Actions.Channels.ListChannels
  alias AllbertAssist.Actions.Channels.SendChannelMessage
  alias AllbertAssist.Actions.Channels.SetupCheck
  alias AllbertAssist.Actions.Channels.ShowChannel
  alias AllbertAssist.Actions.Channels.SignalDoctor
  alias AllbertAssist.Actions.Channels.SignalLinkDevice
  alias AllbertAssist.Actions.Channels.UnlinkChannelIdentity
  alias AllbertAssist.Actions.Channels.WhatsAppDoctor
  alias AllbertAssist.Actions.Coding.Bash, as: CodingBash
  alias AllbertAssist.Actions.Coding.Edit, as: CodingEdit
  alias AllbertAssist.Actions.Coding.Glob, as: CodingGlob
  alias AllbertAssist.Actions.Coding.Grep, as: CodingGrep
  alias AllbertAssist.Actions.Coding.Read, as: CodingRead
  alias AllbertAssist.Actions.Coding.Write, as: CodingWrite
  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Confirmations.DenyConfirmation
  alias AllbertAssist.Actions.Confirmations.ExpireConfirmations
  alias AllbertAssist.Actions.Confirmations.ListConfirmations
  alias AllbertAssist.Actions.Confirmations.ShowConfirmation
  alias AllbertAssist.Actions.Conversations.CompleteThread
  alias AllbertAssist.Actions.Conversations.PersistApprovalMediaResponse
  alias AllbertAssist.Actions.Conversations.RenameThread
  alias AllbertAssist.Actions.Conversations.ResumeThreadOnChannel
  alias AllbertAssist.Actions.Database.RestoreBackup, as: RestoreDatabaseBackup
  alias AllbertAssist.Actions.DynamicPlugins.DisableLiveLoader, as: DisableDynamicLiveLoader
  alias AllbertAssist.Actions.DynamicPlugins.DiscardDraft, as: DiscardDynamicDraft
  alias AllbertAssist.Actions.DynamicPlugins.IntegrateDraft, as: IntegrateDynamicDraft
  alias AllbertAssist.Actions.DynamicPlugins.ListDynamicDrafts
  alias AllbertAssist.Actions.DynamicPlugins.RequestDraft, as: RequestDynamicDraft
  alias AllbertAssist.Actions.DynamicPlugins.RollbackIntegration, as: RollbackDynamicIntegration
  alias AllbertAssist.Actions.DynamicPlugins.RunDraftGate, as: RunDynamicDraftGate
  alias AllbertAssist.Actions.DynamicPlugins.RunDraftTrial, as: RunDynamicDraftTrial
  alias AllbertAssist.Actions.DynamicPlugins.ShowDynamicDraft
  alias AllbertAssist.Actions.DynamicPlugins.ShowDynamicIntegration
  alias AllbertAssist.Actions.Email.SendEmail
  alias AllbertAssist.Actions.FirstModel.Detect, as: FirstModelDetect
  alias AllbertAssist.Actions.FirstModel.InstallOllama
  alias AllbertAssist.Actions.FirstModel.PullModel
  alias AllbertAssist.Actions.Image.GenerateImage
  alias AllbertAssist.Actions.Integrations.OpenCalendarPanel
  alias AllbertAssist.Actions.Integrations.OpenGithubPanel
  alias AllbertAssist.Actions.Integrations.OpenMailPanel
  alias AllbertAssist.Actions.Intent.ActivateSkill
  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.Coverage, as: IntentCoverage
  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Intent.DisableDescriptor, as: DisableIntentDescriptor
  alias AllbertAssist.Actions.Intent.Doctor, as: IntentDoctor
  alias AllbertAssist.Actions.Intent.EditDescriptor, as: EditIntentDescriptor
  alias AllbertAssist.Actions.Intent.EnableDescriptor, as: EnableIntentDescriptor
  alias AllbertAssist.Actions.Intent.EvalAdd, as: IntentEvalAdd
  alias AllbertAssist.Actions.Intent.EvalBaseline, as: IntentEvalBaseline
  alias AllbertAssist.Actions.Intent.EvalCapture, as: IntentEvalCapture
  alias AllbertAssist.Actions.Intent.EvalRun, as: IntentEvalRun
  alias AllbertAssist.Actions.Intent.ExplainIntent
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListDescriptors, as: IntentListDescriptors
  alias AllbertAssist.Actions.Intent.ListIntentCandidates
  alias AllbertAssist.Actions.Intent.ListReview, as: IntentListReview
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.OptimizeDescriptors, as: OptimizeIntentDescriptors
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.PromoteDescriptor, as: PromoteIntentDescriptor
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill
  alias AllbertAssist.Actions.Intent.ReindexDescriptors, as: ReindexIntentDescriptors
  alias AllbertAssist.Actions.Intent.RunShellCommand
  alias AllbertAssist.Actions.Intent.ShowDescriptor, as: IntentShowDescriptor
  alias AllbertAssist.Actions.Intent.UnsupportedResourceWorkflow
  alias AllbertAssist.Actions.Jobs.CreateJob
  alias AllbertAssist.Actions.Jobs.ListJobs
  alias AllbertAssist.Actions.Jobs.PauseJob
  alias AllbertAssist.Actions.Jobs.RegistryHealth
  alias AllbertAssist.Actions.Jobs.ResumeJob
  alias AllbertAssist.Actions.Jobs.RunJob
  alias AllbertAssist.Actions.Jobs.TraceSummary
  alias AllbertAssist.Actions.Marketplace.Doctor, as: MarketplaceDoctor
  alias AllbertAssist.Actions.Marketplace.InspectEntry, as: InspectMarketplaceEntry
  alias AllbertAssist.Actions.Marketplace.InstallBundle, as: InstallMarketplaceBundle
  alias AllbertAssist.Actions.Marketplace.ListEntries, as: ListMarketplaceEntries
  alias AllbertAssist.Actions.Marketplace.ListInstalled, as: ListInstalledMarketplaceBundles
  alias AllbertAssist.Actions.Marketplace.RollbackInstall, as: RollbackMarketplaceInstall
  alias AllbertAssist.Actions.Marketplace.VerifyBundleHash, as: VerifyMarketplaceBundleHash
  alias AllbertAssist.Actions.Mcp.CallTool, as: McpCallTool
  alias AllbertAssist.Actions.Mcp.ConnectServer, as: McpConnectServer
  alias AllbertAssist.Actions.Mcp.DoctorServer, as: McpDoctorServer
  alias AllbertAssist.Actions.Mcp.EvaluateServer, as: McpEvaluateServer
  alias AllbertAssist.Actions.Mcp.FetchServerManifest, as: McpFetchServerManifest
  alias AllbertAssist.Actions.Mcp.FindTools, as: McpFindTools
  alias AllbertAssist.Actions.Mcp.ListResources, as: McpListResources
  alias AllbertAssist.Actions.Mcp.ListTools, as: McpListTools
  alias AllbertAssist.Actions.Mcp.ReadResource, as: McpReadResource
  alias AllbertAssist.Actions.Mcp.ScanEnable, as: McpScanEnable
  alias AllbertAssist.Actions.Mcp.ScanPause, as: McpScanPause
  alias AllbertAssist.Actions.Mcp.ScanResume, as: McpScanResume
  alias AllbertAssist.Actions.Mcp.ScanRunOnce, as: McpScanRunOnce
  alias AllbertAssist.Actions.Memory.CompileMemoryIndex
  alias AllbertAssist.Actions.Memory.DeleteMemoryEntry
  alias AllbertAssist.Actions.Memory.ListMemoryCategorySummary
  alias AllbertAssist.Actions.Memory.ListMemoryEntries
  alias AllbertAssist.Actions.Memory.PromoteConversationTurn
  alias AllbertAssist.Actions.Memory.PruneMemoryEntries
  alias AllbertAssist.Actions.Memory.ReadMemoryEntry
  alias AllbertAssist.Actions.Memory.RetrieveActiveMemory
  alias AllbertAssist.Actions.Memory.ReviewMemoryEntry
  alias AllbertAssist.Actions.Memory.SearchMemory
  alias AllbertAssist.Actions.Memory.SummarizeMemoryCategory
  alias AllbertAssist.Actions.Memory.SyncAppLesson
  alias AllbertAssist.Actions.Memory.UpdateMemoryEntry
  alias AllbertAssist.Actions.Objectives.CancelObjective
  alias AllbertAssist.Actions.Objectives.CancelObjectiveRun
  alias AllbertAssist.Actions.Objectives.ContinueObjective
  alias AllbertAssist.Actions.Objectives.DelegateAgent
  alias AllbertAssist.Actions.Objectives.ListObjectives
  alias AllbertAssist.Actions.Objectives.ShowObjective
  alias AllbertAssist.Actions.Objectives.StartFanout
  alias AllbertAssist.Actions.Operator.Channels, as: OperatorChannels
  alias AllbertAssist.Actions.Operator.Confirmations, as: OperatorConfirmations
  alias AllbertAssist.Actions.Operator.Events, as: OperatorEvents
  alias AllbertAssist.Actions.Operator.SettingGet, as: OperatorSettingGet
  alias AllbertAssist.Actions.Operator.Status, as: OperatorStatus
  alias AllbertAssist.Actions.Packages.PlanPackageInstall
  alias AllbertAssist.Actions.Packages.RunPackageInstall
  alias AllbertAssist.Actions.PlanBuild.CancelPlanRun
  alias AllbertAssist.Actions.PlanBuild.ConfirmPlanStep
  alias AllbertAssist.Actions.PlanBuild.ExpandWorkflow
  alias AllbertAssist.Actions.PlanBuild.InspectWorkflow
  alias AllbertAssist.Actions.PlanBuild.ListPlanRuns
  alias AllbertAssist.Actions.PlanBuild.ListWorkflows
  alias AllbertAssist.Actions.PlanBuild.PreviewPlan
  alias AllbertAssist.Actions.PlanBuild.StartPlanRun
  alias AllbertAssist.Actions.Plugins.ListPlugins
  alias AllbertAssist.Actions.Plugins.ShowPlugin
  alias AllbertAssist.Actions.PublicProtocol.CreateProtocolToken
  alias AllbertAssist.Actions.PublicProtocol.GetPublicCallResult
  alias AllbertAssist.Actions.PublicProtocol.RevokeProtocolToken
  alias AllbertAssist.Actions.PublicProtocol.RotateProtocolToken
  alias AllbertAssist.Actions.Resources.ListResourceGrants
  alias AllbertAssist.Actions.Resources.RememberResourceGrant
  alias AllbertAssist.Actions.Resources.RevokeResourceGrant
  alias AllbertAssist.Actions.Resources.ShowResourceGrant
  alias AllbertAssist.Actions.Sandbox.BuildBundle, as: BuildSandboxBundle
  alias AllbertAssist.Actions.Sandbox.DiscardBundle, as: DiscardSandboxBundle
  alias AllbertAssist.Actions.Sandbox.Doctor, as: SandboxDoctor
  alias AllbertAssist.Actions.Sandbox.RunCommand, as: RunSandboxCommand
  alias AllbertAssist.Actions.Sandbox.RunGate, as: RunSandboxGate
  alias AllbertAssist.Actions.Security.Review, as: SecurityReview
  alias AllbertAssist.Actions.Security.Status, as: SecurityStatus
  alias AllbertAssist.Actions.SelfImprovement.CreateDraft, as: CreateSelfImprovementDraft
  alias AllbertAssist.Actions.SelfImprovement.DiscardDraft, as: DiscardSelfImprovementDraft
  alias AllbertAssist.Actions.SelfImprovement.DiscoverPatterns
  alias AllbertAssist.Actions.SelfImprovement.PromoteCapabilityGapDraft
  alias AllbertAssist.Actions.SelfImprovement.PromoteMemoryDraft
  alias AllbertAssist.Actions.SelfImprovement.PromoteObjectiveDraft
  alias AllbertAssist.Actions.SelfImprovement.PromoteSkillDraft
  alias AllbertAssist.Actions.SelfImprovement.PromoteTemplateDraft
  alias AllbertAssist.Actions.SelfImprovement.PromoteWorkflowDraft
  alias AllbertAssist.Actions.Serve.ServeHealth
  alias AllbertAssist.Actions.Serve.ServiceControl
  alias AllbertAssist.Actions.Session.ClearActiveApp
  alias AllbertAssist.Actions.Session.SetActiveApp
  alias AllbertAssist.Actions.Session.ShowSessionScratchpad
  alias AllbertAssist.Actions.Sessions.ClearSession
  alias AllbertAssist.Actions.Sessions.SweepExpiredSessions
  alias AllbertAssist.Actions.Settings.ApplyPersonaProfile
  alias AllbertAssist.Actions.Settings.Doctor, as: SettingsDoctor
  alias AllbertAssist.Actions.Settings.DoctorModelProfile
  alias AllbertAssist.Actions.Settings.DoctorVoiceProvider
  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.MigrateSecrets
  alias AllbertAssist.Actions.Settings.ModelDoctor, as: SettingsModelDoctor
  alias AllbertAssist.Actions.Settings.ReadSetting
  alias AllbertAssist.Actions.Settings.ResolvedSettingsSnapshot
  alias AllbertAssist.Actions.Settings.SetActiveModelProfile
  alias AllbertAssist.Actions.Settings.SetNotesRoot
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Actions.Settings.UpdateSetting
  alias AllbertAssist.Actions.Settings.VaultStatus
  alias AllbertAssist.Actions.Skills.AuditOnlineSkill
  alias AllbertAssist.Actions.Skills.CreateSkill
  alias AllbertAssist.Actions.Skills.ImportLocalSkill
  alias AllbertAssist.Actions.Skills.ImportOnlineSkill
  alias AllbertAssist.Actions.Skills.ImportRemoteSkill
  alias AllbertAssist.Actions.Skills.RunSkillScript
  alias AllbertAssist.Actions.Skills.SearchOnlineSkills
  alias AllbertAssist.Actions.Skills.ShowOnlineSkill
  alias AllbertAssist.Actions.Skills.ValidateSkill
  alias AllbertAssist.Actions.SurfacePolicy.Read, as: ReadSurfacePolicy
  alias AllbertAssist.Actions.SurfacePolicy.Update, as: UpdateSurfacePolicy
  alias AllbertAssist.Actions.Templates.CreateFromTemplate
  alias AllbertAssist.Actions.Templates.RenderTemplate
  alias AllbertAssist.Actions.Templates.ScaffoldTemplate
  alias AllbertAssist.Actions.Templates.ValidateTemplate
  alias AllbertAssist.Actions.Tools.FindLocalTools
  alias AllbertAssist.Actions.Tools.FindTools
  alias AllbertAssist.Actions.Trace.RecordTrace
  alias AllbertAssist.Actions.Voice.CaptureWorkspaceVoice
  alias AllbertAssist.Actions.Voice.EnsureVoiceToken
  alias AllbertAssist.Actions.Voice.LocalRuntimeDoctor
  alias AllbertAssist.Actions.Voice.StartLocalRuntime
  alias AllbertAssist.Actions.Voice.SynthesizeVoice
  alias AllbertAssist.Actions.Voice.TranscribeVoice
  alias AllbertAssist.Actions.Workspace.DismissEphemeral
  alias AllbertAssist.Actions.Workspace.ManageTile
  alias AllbertAssist.Actions.Workspace.RecordOfflineUpdate
  alias AllbertAssist.Actions.Workspace.RevertTileRevision
  alias AllbertAssist.Actions.Workspace.RotateSigningSecret
  alias AllbertAssist.Actions.Workspace.SetTheme
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry
  alias AllbertAssist.RegistryContext
  alias AllbertAssist.Signals

  @agent_actions [
    DirectAnswer,
    AppendMemory,
    ReadRecentMemory,
    ListSkills,
    ReadSkill,
    ActivateSkill,
    PlanShellCommand,
    RunShellCommand,
    UnsupportedResourceWorkflow,
    ExternalNetworkRequest,
    PlanPackageInstall,
    SearchOnlineSkills,
    ShowOnlineSkill,
    ListSettings,
    ReadSetting,
    UpdateSetting,
    SetNotesRoot,
    ExplainSetting,
    ListProviderProfiles,
    ListModelProfiles,
    SetProviderCredential,
    DoctorModelProfile,
    DoctorVoiceProvider,
    SetActiveModelProfile,
    GenerateImage,
    SynthesizeVoice,
    ListChannels,
    ShowChannel,
    SetupCheck,
    ResumeThreadOnChannel,
    ListApps,
    ShowApp,
    ListPlugins,
    ShowPlugin,
    GetPublicCallResult,
    PreviewPlan,
    OpenCalendarPanel,
    OpenMailPanel,
    OpenGithubPanel,
    # v0.54 M9.1: read-only verbs promoted from :internal to :agent so the router
    # can route to them (capability exposure also flipped to :agent). Effectful
    # internal verbs stay internal pending a confirmation-gate decision.
    ListMarketplaceEntries,
    ListObjectives,
    McpFindTools,
    # v0.54 M10 outbound compose actions (ADR 0063)
    SendEmail,
    SendChannelMessage,
    CreateCalendarEvent,
    # v0.54 M10 effectful-verb promotions (gated; cancel_objective stays not_required)
    InstallMarketplaceBundle,
    CreateSkill,
    ContinueObjective,
    CancelObjective,
    CancelObjectiveRun
  ]

  @internal_actions [
    # Coding actions are session-only Pi-mode tools. Keep them registered for
    # Runner.run/3 but out of the general intent-agent surface.
    CodingRead,
    CodingGrep,
    CodingGlob,
    CodingWrite,
    CodingEdit,
    CodingBash,
    StartFanout,
    # Channel doctors declare exposure: :internal; keep them out of the agent set
    # so agent_modules/0 agrees with capability exposure (v0.54 M9.1 reconcile).
    WhatsAppDoctor,
    SignalDoctor,
    McpDoctorServer,
    McpListTools,
    McpListResources,
    McpReadResource,
    McpCallTool,
    McpFetchServerManifest,
    McpEvaluateServer,
    McpConnectServer,
    McpScanEnable,
    McpScanPause,
    McpScanResume,
    McpScanRunOnce,
    FindLocalTools,
    FindTools,
    DiscoverPatterns,
    CreateSelfImprovementDraft,
    DiscardSelfImprovementDraft,
    PromoteSkillDraft,
    PromoteWorkflowDraft,
    PromoteMemoryDraft,
    PromoteTemplateDraft,
    PromoteObjectiveDraft,
    PromoteCapabilityGapDraft,
    ValidateSkill,
    RunSkillScript,
    RunPackageInstall,
    AuditOnlineSkill,
    ImportOnlineSkill,
    ImportRemoteSkill,
    ImportLocalSkill,
    MarketplaceDoctor,
    InspectMarketplaceEntry,
    RollbackMarketplaceInstall,
    ListInstalledMarketplaceBundles,
    VerifyMarketplaceBundleHash,
    PutArtifact,
    GetArtifact,
    ListArtifacts,
    ArtifactThreads,
    DeleteArtifact,
    ArtifactDoctor,
    SecurityStatus,
    SecurityReview,
    SandboxDoctor,
    BuildSandboxBundle,
    RunSandboxCommand,
    RunSandboxGate,
    DiscardSandboxBundle,
    OperatorStatus,
    OperatorConfirmations,
    OperatorEvents,
    OperatorChannels,
    OperatorSettingGet,
    ReadSurfacePolicy,
    UpdateSurfacePolicy,
    SettingsDoctor,
    SettingsModelDoctor,
    ResolvedSettingsSnapshot,
    ListConfirmations,
    ShowConfirmation,
    ApproveConfirmation,
    DenyConfirmation,
    ExpireConfirmations,
    ListResourceGrants,
    ShowResourceGrant,
    RevokeResourceGrant,
    RememberResourceGrant,
    SetActiveApp,
    ClearActiveApp,
    ShowSessionScratchpad,
    CaptureWorkspaceVoice,
    TranscribeVoice,
    LocalRuntimeDoctor,
    StartLocalRuntime,
    RecordTrace,
    ExplainIntent,
    ListIntentCandidates,
    IntentDoctor,
    IntentListDescriptors,
    IntentShowDescriptor,
    IntentCoverage,
    IntentEvalRun,
    IntentListReview,
    OptimizeIntentDescriptors,
    PromoteIntentDescriptor,
    ReindexIntentDescriptors,
    EditIntentDescriptor,
    DisableIntentDescriptor,
    EnableIntentDescriptor,
    IntentEvalBaseline,
    IntentEvalCapture,
    IntentEvalAdd,
    ListMemoryEntries,
    ReadMemoryEntry,
    ReviewMemoryEntry,
    UpdateMemoryEntry,
    DeleteMemoryEntry,
    PruneMemoryEntries,
    SearchMemory,
    CompileMemoryIndex,
    SummarizeMemoryCategory,
    ListMemoryCategorySummary,
    RetrieveActiveMemory,
    PromoteConversationTurn,
    SyncAppLesson,
    ShowObjective,
    DelegateAgent,
    ListWorkflows,
    InspectWorkflow,
    ExpandWorkflow,
    StartPlanRun,
    ConfirmPlanStep,
    CancelPlanRun,
    ListPlanRuns,
    RegistryHealth,
    TraceSummary,
    ListJobs,
    PauseJob,
    ResumeJob,
    RunJob,
    # v0.62 M8.15 one-spine: job create routed off the CLI area's direct
    # Jobs.create_job onto the :job_write gate.
    CreateJob,
    # v0.61b M4: operator-surface thread rename; internal like the job controls —
    # the UI calls it via Runner; the intent router does not route to it.
    RenameThread,
    # v0.62 M0.1: the approval-media assistant-message write, off the LiveView
    # direct-write path and onto the spine (internal, Runner-only).
    PersistApprovalMediaResponse,
    # v0.62 M4: First-Model-Path — detect (read-only), install (command_execute,
    # confirmed), pull (external_network, confirmed). Internal; not agent-routable.
    FirstModelDetect,
    InstallOllama,
    PullModel,
    # v0.62 M5: serve health (read-only) + per-user service install/uninstall
    # (command_execute, confirmed). Named internal actions, not off-spine shell.
    ServeHealth,
    ServiceControl,
    RestoreDatabaseBackup,
    # v0.62 M7: three-tier secret vault — vault status (read-only) + migrate
    # secrets into the OS vault (settings_write, confirmed). Named internal
    # actions in the packaging-no-authority-change allowance.
    VaultStatus,
    MigrateSecrets,
    # v0.63 M4: apply a reviewed persona preset (settings_write, confirmed).
    # Setup-time internal action; kept off the general agent surface.
    ApplyPersonaProfile,
    ManageTile,
    RevertTileRevision,
    RecordOfflineUpdate,
    DismissEphemeral,
    RotateSigningSecret,
    SetTheme,
    RequestDynamicDraft,
    DiscardDynamicDraft,
    IntegrateDynamicDraft,
    RollbackDynamicIntegration,
    DisableDynamicLiveLoader,
    RunDynamicDraftTrial,
    RunDynamicDraftGate,
    ListDynamicDrafts,
    ShowDynamicDraft,
    ShowDynamicIntegration,
    RenderTemplate,
    ValidateTemplate,
    ScaffoldTemplate,
    CreateFromTemplate,
    SignalLinkDevice,
    # v0.62 M8.15 one-spine: the operator-CLI config areas (channels, sessions,
    # threads, public_protocol, voice) previously wrote to stores/services
    # directly. These internal, Runner-only actions carry those writes through
    # PermissionGate + audit; each reuses an existing permission class.
    ConfigureChannelSecret,
    ConfigureChannelSetting,
    LinkChannelIdentity,
    UnlinkChannelIdentity,
    ClearSession,
    SweepExpiredSessions,
    CompleteThread,
    CreateProtocolToken,
    RotateProtocolToken,
    RevokeProtocolToken,
    EnsureVoiceToken
  ]

  @actions @agent_actions ++ @internal_actions

  @doc "Return registered runtime action modules in stable display order."
  @spec modules(keyword()) :: nonempty_list(module())
  def modules(opts \\ []), do: @actions ++ plugin_actions(opts) ++ dynamic_actions(opts)

  @doc "Return action modules that can be exposed to the intent agent."
  @spec agent_modules(keyword()) :: nonempty_list(module())
  def agent_modules(opts \\ []) do
    @agent_actions ++
      Enum.filter(plugin_actions(opts), fn module ->
        module
        |> module_capability_attrs()
        |> case do
          {:ok, attrs} -> attrs.exposure == :agent
          {:error, _reason} -> false
        end
      end) ++ ActionsOverlay.agent_modules(RegistryContext.overlay_server(opts))
  end

  @doc "Return registered action names in stable display order."
  @spec names(keyword()) :: [String.t()]
  def names(opts \\ []), do: Enum.map(modules(opts), & &1.name())

  @doc "Return canonical capability metadata for all registered actions."
  @spec capabilities(keyword()) :: [Capability.t()]
  def capabilities(opts \\ []), do: Enum.map(modules(opts), &capability_for_module!(&1, opts))

  @doc "Return canonical capability metadata for intent-agent actions."
  @spec agent_capabilities(keyword()) :: [Capability.t()]
  def agent_capabilities(opts \\ []),
    do: Enum.map(agent_modules(opts), &capability_for_module!(&1, opts))

  @doc "Return canonical capability metadata for internal-only actions."
  @spec internal_capabilities(keyword()) :: [Capability.t()]
  def internal_capabilities(opts \\ []) do
    internal_plugin_actions =
      Enum.reject(plugin_actions(opts), fn module ->
        module in agent_modules(opts)
      end)

    dynamic_internal_actions =
      Enum.reject(dynamic_actions(opts), fn module ->
        module in ActionsOverlay.agent_modules(RegistryContext.overlay_server(opts))
      end)

    Enum.map(
      @internal_actions ++ internal_plugin_actions ++ dynamic_internal_actions,
      &capability_for_module!(&1, opts)
    )
  end

  @doc "Return action capabilities contributed by one registered app."
  @spec capabilities_for_app(atom(), keyword()) :: [Capability.t()]
  def capabilities_for_app(app_id, opts \\ [])

  def capabilities_for_app(app_id, opts) when is_atom(app_id) do
    app_id
    |> AppRegistry.actions_for(RegistryContext.app_opts(opts))
    |> Kernel.++(ActionsOverlay.actions_for_app(app_id, RegistryContext.overlay_server(opts)))
    |> Enum.map(&capability_for_module!(&1, opts))
  end

  def capabilities_for_app(_app_id, _opts), do: []

  @doc "Resolve a registered action by module, string name, or atom name."
  @spec resolve(module() | String.t() | atom(), keyword()) ::
          {:ok, module()} | {:error, {:unknown_action, term()}}
  def resolve(action, opts \\ [])

  def resolve(action, opts) when is_atom(action) do
    if action in modules(opts) do
      {:ok, action}
    else
      action
      |> Atom.to_string()
      |> String.replace_prefix("Elixir.", "")
      |> resolve_name(action, opts)
    end
  end

  def resolve(action, opts) when is_binary(action), do: resolve_name(action, action, opts)

  def resolve(action, _opts), do: {:error, {:unknown_action, action}}

  @doc "Resolve canonical capability metadata by registered action name or module."
  @spec capability(module() | String.t() | atom(), keyword()) ::
          {:ok, Capability.t()} | {:error, {:unknown_action, term()}}
  def capability(action, opts \\ []) do
    with {:ok, module} <- resolve(action, opts) do
      {:ok, capability_for_module!(module, opts)}
    end
  end

  @doc "Return true when a registered action may be resumed from a durable confirmation."
  @spec resumable?(module() | String.t() | atom(), keyword()) :: boolean()
  def resumable?(action, opts \\ []) do
    case capability(action, opts) do
      {:ok, capability} -> capability.resumable?
      {:error, _reason} -> false
    end
  end

  @doc "Return true when the module is registered for runtime invocation."
  @spec registered_module?(module(), keyword()) :: boolean()
  def registered_module?(module, opts \\ []), do: module in modules(opts)

  @doc "Return duplicate registered names. This should always be empty."
  @spec duplicate_names(keyword()) :: [String.t()]
  def duplicate_names(opts \\ []) do
    names(opts)
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> name end)
  end

  @doc "Return action registry diagnostics, including plugin action collisions."
  @spec diagnostics(keyword()) :: [map()]
  def diagnostics(opts \\ []) do
    plugin_action_diagnostics(opts) ++
      ActionsOverlay.diagnostics(RegistryContext.overlay_server(opts))
  end

  @doc "Emit an advisory action-registry-changed signal for index subscribers."
  @spec emit_registry_changed(atom(), map()) :: :ok
  def emit_registry_changed(reason, metadata \\ %{}) when is_atom(reason) and is_map(metadata) do
    metadata =
      metadata
      |> Map.put(:reason, reason)
      |> Map.put(:registered_action_count, length(names()))
      |> Map.put(:agent_action_count, length(agent_modules()))

    Signals.emit_registration(:action_registry_changed, metadata)
  end

  # M8.8: resolve walked the FULL catalog re-normalizing every action name
  # per lookup — 110k normalize_name calls inside one Engine.decide (eprof).
  # The static catalog is compile-constant and ordered ahead of plugin/
  # dynamic modules, so a first-match static index answers most lookups in
  # O(1) with identical resolution semantics; only misses scan the (small,
  # registry-context-dependent) plugin + dynamic tail.
  defp resolve_name(name, original, opts) do
    normalized = normalize_name(name)

    case Map.fetch(static_name_index(), normalized) do
      {:ok, module} ->
        {:ok, module}

      :error ->
        plugin_and_dynamic = plugin_actions(opts) ++ dynamic_actions(opts)

        case Enum.find(plugin_and_dynamic, &(normalize_name(&1.name()) == normalized)) do
          nil -> {:error, {:unknown_action, original}}
          module -> {:ok, module}
        end
    end
  end

  defp capability_for_module!(module, opts) do
    attrs = capability_attrs!(module)
    app_id = AppRegistry.app_id_for_action(module, RegistryContext.app_opts(opts))
    plugin_id = PluginRegistry.plugin_id_for_action(module, RegistryContext.plugin_opts(opts))

    module
    |> Capability.new(attrs)
    |> maybe_put_app_id(app_id)
    |> maybe_put_plugin_id(plugin_id)
  end

  defp capability_attrs!(module) do
    case module_capability_attrs(module) do
      {:ok, attrs} ->
        attrs

      {:error, reason} ->
        raise KeyError, key: module, term: reason
    end
  end

  defp module_capability_attrs(module) do
    with true <- Code.ensure_loaded?(module),
         true <- function_exported?(module, :capability, 0) do
      module
      |> apply(:capability, [])
      |> Action.validate_capability()
    else
      false -> {:error, :missing_action_capability}
    end
  end

  defp plugin_actions(opts) do
    entries = plugin_action_entries(opts)
    static_names = static_action_names()
    duplicate_names = duplicate_plugin_action_names(entries)

    entries
    |> Enum.reject(&plugin_action_duplicate?(&1, static_names, duplicate_names))
    |> Enum.map(& &1.module)
  end

  defp dynamic_actions(opts), do: ActionsOverlay.modules(RegistryContext.overlay_server(opts))

  defp plugin_action_entries(opts) do
    opts
    |> RegistryContext.plugin_opts()
    |> PluginRegistry.registered_plugins()
    |> Enum.flat_map(fn plugin ->
      plugin.actions
      |> Enum.filter(&valid_plugin_action?/1)
      |> Enum.reject(&(&1 in @actions))
      |> Enum.map(&%{plugin_id: plugin.plugin_id, module: &1, name: normalize_name(&1.name())})
    end)
  end

  defp plugin_action_duplicate?(entry, static_names, duplicate_names) do
    MapSet.member?(static_names, entry.name) or MapSet.member?(duplicate_names, entry.name)
  end

  defp plugin_action_diagnostics(opts) do
    entries = plugin_action_entries(opts)
    static_names = static_action_names()
    duplicate_names = duplicate_plugin_action_names(entries)

    entries
    |> Enum.filter(&plugin_action_duplicate?(&1, static_names, duplicate_names))
    |> Enum.map(fn entry ->
      %{
        plugin_id: entry.plugin_id,
        kind: :duplicate_action_name,
        severity: :error,
        message: "Plugin action name collides with another registered action.",
        action_name: entry.name,
        action_module: entry.module
      }
    end)
  end

  defp duplicate_plugin_action_names(entries) do
    entries
    |> Enum.map(& &1.name)
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> name end)
    |> MapSet.new()
  end

  # M8.8: both derivations below are pure functions of the compile-constant
  # @actions list, yet were recomputed on every modules/1 and resolve call
  # (plugin_actions/1 alone re-normalized the whole static catalog per
  # invocation). Memoized in persistent_term; no invalidation is needed —
  # the inputs cannot change without a recompile.
  @static_names_key {__MODULE__, :static_action_names}
  @static_index_key {__MODULE__, :static_name_index}

  defp static_action_names do
    case :persistent_term.get(@static_names_key, nil) do
      nil ->
        names = @actions |> Enum.map(&normalize_name(&1.name())) |> MapSet.new()
        :persistent_term.put(@static_names_key, names)
        names

      names ->
        names
    end
  end

  defp static_name_index do
    case :persistent_term.get(@static_index_key, nil) do
      nil ->
        index =
          Enum.reduce(@actions, %{}, fn module, acc ->
            Map.put_new(acc, normalize_name(module.name()), module)
          end)

        :persistent_term.put(@static_index_key, index)
        index

      index ->
        index
    end
  end

  defp valid_plugin_action?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :name, 0) and
      match?({:ok, _attrs}, module_capability_attrs(module))
  end

  defp maybe_put_app_id(capability, nil), do: capability
  defp maybe_put_app_id(capability, app_id), do: %{capability | app_id: app_id}

  defp maybe_put_plugin_id(capability, nil), do: capability
  defp maybe_put_plugin_id(capability, plugin_id), do: %{capability | plugin_id: plugin_id}

  # v1.0.3 M7: 5,416 calls inside one `Engine.decide` (3,293 from
  # `plugin_action_entries/1`, which re-derives and re-normalizes the whole
  # plugin action list per lookup, 2,123 from `resolve_name/3`), each running
  # a Unicode downcase plus a `Regex.replace/4`. Single byte walk, byte-
  # identical on the domain it accepts.
  #
  # Equivalence argument. The fast path accepts ONLY all-ASCII binaries
  # (every byte < 0x80); anything else falls through to the original
  # pipeline, so Unicode case folding is never approximated. On ASCII,
  # `String.downcase/1` is byte-wise `A-Z` -> `a-z`, `[^a-z0-9]+ -> "_"`
  # collapses each maximal run of non-alphanumeric bytes to one underscore,
  # and `String.trim("_")` drops the leading/trailing one — which the walk
  # achieves by never emitting a separator before the first kept byte and
  # never flushing a trailing one.
  defp normalize_name(name) do
    binary = to_string(name)

    case normalize_name_ascii(binary, <<>>, false) do
      :non_ascii ->
        binary
        |> String.downcase()
        |> String.replace(~r/[^a-z0-9]+/, "_")
        |> String.trim("_")

      normalized ->
        normalized
    end
  end

  defp normalize_name_ascii(<<c, rest::binary>>, acc, pending?) when c < 0x80 do
    c = if c >= ?A and c <= ?Z, do: c + 32, else: c

    if (c >= ?a and c <= ?z) or (c >= ?0 and c <= ?9) do
      acc = if pending?, do: <<acc::binary, ?_>>, else: acc
      normalize_name_ascii(rest, <<acc::binary, c>>, false)
    else
      normalize_name_ascii(rest, acc, acc != <<>>)
    end
  end

  defp normalize_name_ascii(<<>>, acc, _pending?), do: acc
  defp normalize_name_ascii(_binary, _acc, _pending?), do: :non_ascii
end
