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
  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Channels.ListChannels
  alias AllbertAssist.Actions.Channels.SetupCheck
  alias AllbertAssist.Actions.Channels.ShowChannel
  alias AllbertAssist.Actions.Calendar.CreateCalendarEvent
  alias AllbertAssist.Actions.Channels.SendChannelMessage
  alias AllbertAssist.Actions.Channels.SignalDoctor
  alias AllbertAssist.Actions.Email.SendEmail
  alias AllbertAssist.Actions.Channels.SignalLinkDevice
  alias AllbertAssist.Actions.Channels.WhatsAppDoctor
  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Confirmations.DenyConfirmation
  alias AllbertAssist.Actions.Confirmations.ExpireConfirmations
  alias AllbertAssist.Actions.Confirmations.ListConfirmations
  alias AllbertAssist.Actions.Confirmations.ShowConfirmation
  alias AllbertAssist.Actions.Conversations.ResumeThreadOnChannel
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
  alias AllbertAssist.Actions.Image.GenerateImage
  alias AllbertAssist.Actions.Integrations.OpenCalendarPanel
  alias AllbertAssist.Actions.Integrations.OpenGithubPanel
  alias AllbertAssist.Actions.Integrations.OpenMailPanel
  alias AllbertAssist.Actions.Intent.ActivateSkill
  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Intent.ExplainIntent
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListIntentCandidates
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill
  alias AllbertAssist.Actions.Intent.RunShellCommand
  alias AllbertAssist.Actions.Intent.UnsupportedResourceWorkflow
  alias AllbertAssist.Actions.Jobs.RegistryHealth
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
  alias AllbertAssist.Actions.Objectives.ContinueObjective
  alias AllbertAssist.Actions.Objectives.DelegateAgent
  alias AllbertAssist.Actions.Objectives.ListObjectives
  alias AllbertAssist.Actions.Objectives.ShowObjective
  alias AllbertAssist.Actions.Onboarding.StepComplete, as: OnboardingStepComplete
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
  alias AllbertAssist.Actions.PublicProtocol.GetPublicCallResult
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
  alias AllbertAssist.Actions.Session.ClearActiveApp
  alias AllbertAssist.Actions.Session.SetActiveApp
  alias AllbertAssist.Actions.Session.ShowSessionScratchpad
  alias AllbertAssist.Actions.Settings.DoctorModelProfile
  alias AllbertAssist.Actions.Settings.DoctorVoiceProvider
  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.ReadSetting
  alias AllbertAssist.Actions.Settings.SetActiveModelProfile
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Actions.Settings.UpdateSetting
  alias AllbertAssist.Actions.Skills.AuditOnlineSkill
  alias AllbertAssist.Actions.Skills.CreateSkill
  alias AllbertAssist.Actions.Skills.ImportLocalSkill
  alias AllbertAssist.Actions.Skills.ImportOnlineSkill
  alias AllbertAssist.Actions.Skills.ImportRemoteSkill
  alias AllbertAssist.Actions.Skills.RunSkillScript
  alias AllbertAssist.Actions.Skills.SearchOnlineSkills
  alias AllbertAssist.Actions.Skills.ShowOnlineSkill
  alias AllbertAssist.Actions.Skills.ValidateSkill
  alias AllbertAssist.Actions.Templates.CreateFromTemplate
  alias AllbertAssist.Actions.Templates.RenderTemplate
  alias AllbertAssist.Actions.Templates.ScaffoldTemplate
  alias AllbertAssist.Actions.Templates.ValidateTemplate
  alias AllbertAssist.Actions.Tools.FindLocalTools
  alias AllbertAssist.Actions.Tools.FindTools
  alias AllbertAssist.Actions.Trace.RecordTrace
  alias AllbertAssist.Actions.Voice.CaptureWorkspaceVoice
  alias AllbertAssist.Actions.Voice.LocalRuntimeDoctor
  alias AllbertAssist.Actions.Voice.StartLocalRuntime
  alias AllbertAssist.Actions.Voice.SynthesizeVoice
  alias AllbertAssist.Actions.Voice.TranscribeVoice
  alias AllbertAssist.Actions.Workspace.DismissEphemeral
  alias AllbertAssist.Actions.Workspace.ManageTile
  alias AllbertAssist.Actions.Workspace.RecordOfflineUpdate
  alias AllbertAssist.Actions.Workspace.RevertTileRevision
  alias AllbertAssist.Actions.Workspace.SetTheme
  alias AllbertAssist.App.Registry, as: AppRegistry
  alias AllbertAssist.DynamicPlugins.ActionsOverlay
  alias AllbertAssist.Plugin.Registry, as: PluginRegistry

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
    CreateCalendarEvent
  ]

  @internal_actions [
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
    CreateSkill,
    RunSkillScript,
    RunPackageInstall,
    AuditOnlineSkill,
    ImportOnlineSkill,
    ImportRemoteSkill,
    ImportLocalSkill,
    MarketplaceDoctor,
    InspectMarketplaceEntry,
    InstallMarketplaceBundle,
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
    CancelObjective,
    ContinueObjective,
    DelegateAgent,
    ListWorkflows,
    InspectWorkflow,
    ExpandWorkflow,
    StartPlanRun,
    ConfirmPlanStep,
    CancelPlanRun,
    ListPlanRuns,
    OnboardingStepComplete,
    RegistryHealth,
    TraceSummary,
    ManageTile,
    RevertTileRevision,
    RecordOfflineUpdate,
    DismissEphemeral,
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
    SignalLinkDevice
  ]

  @actions @agent_actions ++ @internal_actions

  @doc "Return registered runtime action modules in stable display order."
  @spec modules() :: nonempty_list(module())
  def modules, do: @actions ++ plugin_actions() ++ dynamic_actions()

  @doc "Return action modules that can be exposed to the intent agent."
  @spec agent_modules() :: nonempty_list(module())
  def agent_modules do
    @agent_actions ++
      Enum.filter(plugin_actions(), fn module ->
        module
        |> module_capability_attrs()
        |> case do
          {:ok, attrs} -> attrs.exposure == :agent
          {:error, _reason} -> false
        end
      end) ++ ActionsOverlay.agent_modules()
  end

  @doc "Return registered action names in stable display order."
  @spec names() :: [String.t()]
  def names, do: Enum.map(modules(), & &1.name())

  @doc "Return canonical capability metadata for all registered actions."
  @spec capabilities() :: [Capability.t()]
  def capabilities, do: Enum.map(modules(), &capability_for_module!/1)

  @doc "Return canonical capability metadata for intent-agent actions."
  @spec agent_capabilities() :: [Capability.t()]
  def agent_capabilities, do: Enum.map(agent_modules(), &capability_for_module!/1)

  @doc "Return canonical capability metadata for internal-only actions."
  @spec internal_capabilities() :: [Capability.t()]
  def internal_capabilities do
    internal_plugin_actions =
      Enum.reject(plugin_actions(), fn module ->
        module in agent_modules()
      end)

    dynamic_internal_actions =
      Enum.reject(dynamic_actions(), fn module ->
        module in ActionsOverlay.agent_modules()
      end)

    Enum.map(
      @internal_actions ++ internal_plugin_actions ++ dynamic_internal_actions,
      &capability_for_module!/1
    )
  end

  @doc "Return action capabilities contributed by one registered app."
  @spec capabilities_for_app(atom()) :: [Capability.t()]
  def capabilities_for_app(app_id) when is_atom(app_id) do
    app_id
    |> AppRegistry.actions_for()
    |> Kernel.++(ActionsOverlay.actions_for_app(app_id))
    |> Enum.map(&capability_for_module!/1)
  end

  def capabilities_for_app(_app_id), do: []

  @doc "Resolve a registered action by module, string name, or atom name."
  @spec resolve(module() | String.t() | atom()) ::
          {:ok, module()} | {:error, {:unknown_action, term()}}
  def resolve(action) when is_atom(action) do
    if action in modules() do
      {:ok, action}
    else
      action
      |> Atom.to_string()
      |> String.replace_prefix("Elixir.", "")
      |> resolve_name(action)
    end
  end

  def resolve(action) when is_binary(action), do: resolve_name(action, action)

  def resolve(action), do: {:error, {:unknown_action, action}}

  @doc "Resolve canonical capability metadata by registered action name or module."
  @spec capability(module() | String.t() | atom()) ::
          {:ok, Capability.t()} | {:error, {:unknown_action, term()}}
  def capability(action) do
    with {:ok, module} <- resolve(action) do
      {:ok, capability_for_module!(module)}
    end
  end

  @doc "Return true when a registered action may be resumed from a durable confirmation."
  @spec resumable?(module() | String.t() | atom()) :: boolean()
  def resumable?(action) do
    case capability(action) do
      {:ok, capability} -> capability.resumable?
      {:error, _reason} -> false
    end
  end

  @doc "Return true when the module is registered for runtime invocation."
  @spec registered_module?(module()) :: boolean()
  def registered_module?(module), do: module in modules()

  @doc "Return duplicate registered names. This should always be empty."
  @spec duplicate_names() :: [String.t()]
  def duplicate_names do
    names()
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> name end)
  end

  @doc "Return action registry diagnostics, including plugin action collisions."
  @spec diagnostics() :: [map()]
  def diagnostics, do: plugin_action_diagnostics() ++ ActionsOverlay.diagnostics()

  defp resolve_name(name, original) do
    normalized = normalize_name(name)

    case Enum.find(modules(), &(normalize_name(&1.name()) == normalized)) do
      nil -> {:error, {:unknown_action, original}}
      module -> {:ok, module}
    end
  end

  defp capability_for_module!(module) do
    attrs = capability_attrs!(module)
    app_id = AppRegistry.app_id_for_action(module)
    plugin_id = PluginRegistry.plugin_id_for_action(module)

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

  defp plugin_actions do
    plugin_action_entries()
    |> Enum.reject(&plugin_action_duplicate?/1)
    |> Enum.map(& &1.module)
  end

  defp dynamic_actions, do: ActionsOverlay.modules()

  defp plugin_action_entries do
    PluginRegistry.registered_plugins()
    |> Enum.flat_map(fn plugin ->
      plugin.actions
      |> Enum.filter(&valid_plugin_action?/1)
      |> Enum.reject(&(&1 in @actions))
      |> Enum.map(&%{plugin_id: plugin.plugin_id, module: &1, name: normalize_name(&1.name())})
    end)
  end

  defp plugin_action_duplicate?(entry) do
    entry.name in static_action_names() or
      entry.name in duplicate_plugin_action_names()
  end

  defp plugin_action_diagnostics do
    plugin_action_entries()
    |> Enum.filter(&plugin_action_duplicate?/1)
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

  defp duplicate_plugin_action_names do
    plugin_action_entries()
    |> Enum.map(& &1.name)
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> name end)
  end

  defp static_action_names do
    Enum.map(@actions, &normalize_name(&1.name()))
  end

  defp valid_plugin_action?(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :name, 0) and
      match?({:ok, _attrs}, module_capability_attrs(module))
  end

  defp maybe_put_app_id(capability, nil), do: capability
  defp maybe_put_app_id(capability, app_id), do: %{capability | app_id: app_id}

  defp maybe_put_plugin_id(capability, nil), do: capability
  defp maybe_put_plugin_id(capability, plugin_id), do: %{capability | plugin_id: plugin_id}

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
