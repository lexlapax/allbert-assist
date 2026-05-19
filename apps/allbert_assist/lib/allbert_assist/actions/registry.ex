defmodule AllbertAssist.Actions.Registry do
  @moduledoc """
  Canonical registry for Allbert runtime-facing Jido actions.

  Pure domain modules can remain plain Elixir behind these actions. Runtime
  callers should resolve action names or modules through this registry before
  invoking work.
  """

  alias AllbertAssist.Actions.Apps.ListApps
  alias AllbertAssist.Actions.Apps.ShowApp
  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Channels.ListChannels
  alias AllbertAssist.Actions.Channels.ShowChannel
  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Confirmations.DenyConfirmation
  alias AllbertAssist.Actions.Confirmations.ExpireConfirmations
  alias AllbertAssist.Actions.Confirmations.ListConfirmations
  alias AllbertAssist.Actions.Confirmations.ShowConfirmation
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
  alias AllbertAssist.Actions.Memory.CompileMemoryIndex
  alias AllbertAssist.Actions.Memory.DeleteMemoryEntry
  alias AllbertAssist.Actions.Memory.ListMemoryCategorySummary
  alias AllbertAssist.Actions.Memory.ListMemoryEntries
  alias AllbertAssist.Actions.Memory.PromoteConversationTurn
  alias AllbertAssist.Actions.Memory.PruneMemoryEntries
  alias AllbertAssist.Actions.Memory.ReadMemoryEntry
  alias AllbertAssist.Actions.Memory.ReviewMemoryEntry
  alias AllbertAssist.Actions.Memory.SearchMemory
  alias AllbertAssist.Actions.Memory.SummarizeMemoryCategory
  alias AllbertAssist.Actions.Memory.UpdateMemoryEntry
  alias AllbertAssist.Actions.Objectives.CancelObjective
  alias AllbertAssist.Actions.Objectives.ContinueObjective
  alias AllbertAssist.Actions.Objectives.DelegateAgent
  alias AllbertAssist.Actions.Objectives.ListObjectives
  alias AllbertAssist.Actions.Objectives.ShowObjective
  alias AllbertAssist.Actions.Packages.PlanPackageInstall
  alias AllbertAssist.Actions.Packages.RunPackageInstall
  alias AllbertAssist.Actions.Plugins.ListPlugins
  alias AllbertAssist.Actions.Plugins.ShowPlugin
  alias AllbertAssist.Actions.Resources.ListResourceGrants
  alias AllbertAssist.Actions.Resources.RememberResourceGrant
  alias AllbertAssist.Actions.Resources.RevokeResourceGrant
  alias AllbertAssist.Actions.Resources.ShowResourceGrant
  alias AllbertAssist.Actions.Security.Status, as: SecurityStatus
  alias AllbertAssist.Actions.Session.ClearActiveApp
  alias AllbertAssist.Actions.Session.SetActiveApp
  alias AllbertAssist.Actions.Session.ShowSessionScratchpad
  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.ReadSetting
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
  alias AllbertAssist.Actions.Trace.RecordTrace
  alias AllbertAssist.Actions.Workspace.DismissEphemeral
  alias AllbertAssist.Actions.Workspace.RecordOfflineUpdate
  alias AllbertAssist.Actions.Workspace.RevertTileRevision
  alias AllbertAssist.Actions.Workspace.SetTheme
  alias AllbertAssist.App.Registry, as: AppRegistry
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
    ListChannels,
    ShowChannel,
    ListApps,
    ShowApp,
    ListPlugins,
    ShowPlugin
  ]

  @internal_actions [
    ValidateSkill,
    CreateSkill,
    RunSkillScript,
    RunPackageInstall,
    AuditOnlineSkill,
    ImportOnlineSkill,
    ImportRemoteSkill,
    ImportLocalSkill,
    SecurityStatus,
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
    PromoteConversationTurn,
    ListObjectives,
    ShowObjective,
    CancelObjective,
    ContinueObjective,
    DelegateAgent,
    RegistryHealth,
    TraceSummary,
    RevertTileRevision,
    RecordOfflineUpdate,
    DismissEphemeral,
    SetTheme
  ]

  @actions @agent_actions ++ @internal_actions

  @capability_attrs %{
    DirectAnswer => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: true,
      confirmation: :not_required
    },
    AppendMemory => %{
      permission: :memory_write,
      exposure: :agent,
      execution_mode: :memory_write,
      skill_backed?: true,
      confirmation: :not_required
    },
    ReadRecentMemory => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: true,
      confirmation: :not_required
    },
    ListSkills => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: true,
      confirmation: :not_required
    },
    ReadSkill => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: true,
      confirmation: :not_required
    },
    ActivateSkill => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required,
      notes: "Progressive disclosure only; does not run the activated skill."
    },
    PlanShellCommand => %{
      permission: :command_plan,
      exposure: :agent,
      execution_mode: :command_plan_only,
      skill_backed?: true,
      confirmation: :not_required
    },
    RunShellCommand => %{
      permission: :command_execute,
      exposure: :agent,
      execution_mode: :local_process,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true,
      notes:
        "v0.08 Level 1 local process execution; creates a durable confirmation before running."
    },
    UnsupportedResourceWorkflow => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :unsupported_resource_workflow,
      skill_backed?: true,
      confirmation: :not_required,
      notes:
        "Inert v0.10 explanation for URL/document/MCP/agent/channel workflows owned by v0.11+."
    },
    ExternalNetworkRequest => %{
      permission: :external_network,
      exposure: :agent,
      execution_mode: :req_http,
      skill_backed?: true,
      confirmation: :required,
      resumable?: true,
      notes: "v0.10 confirmed Req HTTP execution; creates a durable confirmation before running."
    },
    PlanPackageInstall => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :package_install_plan,
      skill_backed?: true,
      confirmation: :not_required,
      notes: "Plans package work only; package managers must run through run_package_install."
    },
    SearchOnlineSkills => %{
      permission: :external_network,
      exposure: :agent,
      execution_mode: :online_skill_search,
      skill_backed?: true,
      confirmation: :required,
      resumable?: true,
      notes: "Searches online skill source profiles only after external-network confirmation."
    },
    ShowOnlineSkill => %{
      permission: :external_network,
      exposure: :agent,
      execution_mode: :online_skill_detail,
      skill_backed?: true,
      confirmation: :required,
      resumable?: true,
      notes: "Fetches online skill details only after external-network confirmation."
    },
    ListSettings => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ReadSetting => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    UpdateSetting => %{
      permission: :settings_write,
      exposure: :agent,
      execution_mode: :settings_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    ExplainSetting => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListProviderProfiles => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListModelProfiles => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    SetProviderCredential => %{
      permission: :settings_secret_write,
      exposure: :agent,
      execution_mode: :secret_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListApps => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ShowApp => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListChannels => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ShowChannel => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListPlugins => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ShowPlugin => %{
      permission: :read_only,
      exposure: :agent,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ValidateSkill => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :skill_validation,
      skill_backed?: false,
      confirmation: :not_required,
      notes: "Operator helper; validates local skill folders without trusting or executing them."
    },
    CreateSkill => %{
      permission: :skill_write,
      exposure: :internal,
      execution_mode: :skill_write,
      skill_backed?: false,
      confirmation: :not_required,
      notes: "Operator helper; writes standard SKILL.md scaffolds only."
    },
    RunSkillScript => %{
      permission: :skill_script_execute,
      exposure: :internal,
      execution_mode: :skill_script_process,
      skill_backed?: true,
      confirmation: :required,
      resumable?: true,
      notes:
        "v0.09 trusted resource-gated skill script execution; M2 resolves inert specs before M3 confirmations and M4 running."
    },
    RunPackageInstall => %{
      permission: :package_install,
      exposure: :internal,
      execution_mode: :package_manager_process,
      skill_backed?: true,
      confirmation: :required,
      resumable?: true,
      notes: "Runs confirmed npm package-manager process execution; pip remains preview-only."
    },
    AuditOnlineSkill => %{
      permission: :external_network,
      exposure: :internal,
      execution_mode: :online_skill_audit,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true,
      notes: "Fetches and audits online skill metadata only after external-network confirmation."
    },
    ImportOnlineSkill => %{
      permission: :online_skill_import,
      exposure: :internal,
      execution_mode: :online_skill_import,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true,
      notes: "Imports online skill files into the disabled, untrusted cache after confirmation."
    },
    ImportRemoteSkill => %{
      permission: :online_skill_import,
      exposure: :internal,
      execution_mode: :direct_skill_import,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true,
      notes:
        "Imports a direct HTTPS skill URL into the disabled, untrusted cache after confirmation."
    },
    ImportLocalSkill => %{
      permission: :skill_write,
      exposure: :internal,
      execution_mode: :local_skill_import,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true,
      notes:
        "Imports a local skill directory into the disabled, untrusted cache after confirmation."
    },
    SecurityStatus => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :security_status,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListConfirmations => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :confirmation_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ShowConfirmation => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :confirmation_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ApproveConfirmation => %{
      permission: :confirmation_decide,
      exposure: :internal,
      execution_mode: :confirmation_decision,
      skill_backed?: false,
      confirmation: :not_required,
      notes: "Approves a pending request; target resumption remains version-scoped."
    },
    DenyConfirmation => %{
      permission: :confirmation_decide,
      exposure: :internal,
      execution_mode: :confirmation_decision,
      skill_backed?: false,
      confirmation: :not_required
    },
    ExpireConfirmations => %{
      permission: :confirmation_decide,
      exposure: :internal,
      execution_mode: :confirmation_cleanup,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListResourceGrants => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :resource_grant_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ShowResourceGrant => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :resource_grant_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    RevokeResourceGrant => %{
      permission: :confirmation_decide,
      exposure: :internal,
      execution_mode: :resource_grant_revoke,
      skill_backed?: false,
      confirmation: :not_required
    },
    RememberResourceGrant => %{
      permission: :confirmation_decide,
      exposure: :internal,
      execution_mode: :resource_grant_remember,
      skill_backed?: false,
      confirmation: :not_required
    },
    SetActiveApp => %{
      permission: :settings_write,
      exposure: :internal,
      execution_mode: :settings_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    ClearActiveApp => %{
      permission: :settings_write,
      exposure: :internal,
      execution_mode: :settings_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    ShowSessionScratchpad => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :settings_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    RecordTrace => %{
      permission: :memory_write,
      exposure: :internal,
      execution_mode: :internal_trace,
      skill_backed?: false,
      confirmation: :not_required
    },
    ExplainIntent => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListIntentCandidates => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListMemoryEntries => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :memory_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ReadMemoryEntry => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :memory_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ReviewMemoryEntry => %{
      permission: :memory_write,
      exposure: :internal,
      execution_mode: :memory_review,
      skill_backed?: false,
      confirmation: :not_required
    },
    UpdateMemoryEntry => %{
      permission: :memory_write,
      exposure: :internal,
      execution_mode: :memory_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    DeleteMemoryEntry => %{
      permission: :memory_write,
      exposure: :internal,
      execution_mode: :memory_archive,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true
    },
    PruneMemoryEntries => %{
      permission: :memory_write,
      exposure: :internal,
      execution_mode: :memory_archive,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true
    },
    SearchMemory => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :memory_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    CompileMemoryIndex => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :memory_index_compile,
      skill_backed?: false,
      confirmation: :not_required
    },
    SummarizeMemoryCategory => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :memory_summary_compile,
      skill_backed?: false,
      confirmation: :not_required
    },
    ListMemoryCategorySummary => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :memory_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    PromoteConversationTurn => %{
      permission: :memory_write,
      exposure: :internal,
      execution_mode: :memory_promotion,
      skill_backed?: false,
      confirmation: :required,
      resumable?: true
    },
    ListObjectives => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :objectives_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    ShowObjective => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :objectives_read,
      skill_backed?: false,
      confirmation: :not_required
    },
    CancelObjective => %{
      permission: :objective_write,
      exposure: :internal,
      execution_mode: :objective_engine,
      skill_backed?: false,
      confirmation: :not_required
    },
    ContinueObjective => %{
      permission: :objective_write,
      exposure: :internal,
      execution_mode: :objective_engine,
      skill_backed?: false,
      confirmation: :not_required
    },
    DelegateAgent => %{
      permission: :objective_write,
      exposure: :internal,
      execution_mode: :objective_delegate,
      skill_backed?: false,
      confirmation: :not_required
    },
    RegistryHealth => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required
    },
    TraceSummary => %{
      permission: :read_only,
      exposure: :internal,
      execution_mode: :read_only,
      skill_backed?: false,
      confirmation: :not_required
    },
    RevertTileRevision => %{
      permission: :workspace_canvas_write,
      exposure: :internal,
      execution_mode: :workspace_canvas_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    RecordOfflineUpdate => %{
      permission: :workspace_canvas_write,
      exposure: :internal,
      execution_mode: :workspace_canvas_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    DismissEphemeral => %{
      permission: :workspace_canvas_write,
      exposure: :internal,
      execution_mode: :workspace_canvas_write,
      skill_backed?: false,
      confirmation: :not_required
    },
    SetTheme => %{
      permission: :settings_write,
      exposure: :internal,
      execution_mode: :settings_write,
      skill_backed?: false,
      confirmation: :not_required
    }
  }

  @doc "Return registered runtime action modules in stable display order."
  @spec modules() :: nonempty_list(module())
  def modules, do: @actions ++ plugin_actions()

  @doc "Return action modules that can be exposed to the intent agent."
  @spec agent_modules() :: nonempty_list(module())
  def agent_modules do
    @agent_actions ++
      Enum.filter(plugin_actions(), fn module ->
        module
        |> plugin_capability_attrs()
        |> case do
          {:ok, attrs} -> attrs.exposure == :agent
          {:error, _reason} -> false
        end
      end)
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

    Enum.map(@internal_actions ++ internal_plugin_actions, &capability_for_module!/1)
  end

  @doc "Return action capabilities contributed by one registered app."
  @spec capabilities_for_app(atom()) :: [Capability.t()]
  def capabilities_for_app(app_id) when is_atom(app_id) do
    app_id
    |> AppRegistry.actions_for()
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
  def diagnostics, do: plugin_action_diagnostics()

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
    case Map.fetch(@capability_attrs, module) do
      {:ok, attrs} ->
        attrs

      :error ->
        case plugin_capability_attrs(module) do
          {:ok, attrs} -> attrs
          {:error, reason} -> raise KeyError, key: module, term: reason
        end
    end
  end

  defp plugin_actions do
    plugin_action_entries()
    |> Enum.reject(&plugin_action_duplicate?/1)
    |> Enum.map(& &1.module)
  end

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
      match?({:ok, _attrs}, plugin_capability_attrs(module))
  end

  defp plugin_capability_attrs(module) do
    if function_exported?(module, :capability, 0) do
      attrs = module.capability()

      required = [:permission, :exposure, :execution_mode, :skill_backed?, :confirmation]

      if is_map(attrs) and Enum.all?(required, &Map.has_key?(attrs, &1)) do
        {:ok, attrs}
      else
        {:error, :invalid_plugin_capability}
      end
    else
      {:error, :missing_plugin_capability}
    end
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
