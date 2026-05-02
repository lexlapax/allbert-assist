defmodule AllbertAssist.Actions.Registry do
  @moduledoc """
  Canonical registry for Allbert runtime-facing Jido actions.

  Pure domain modules can remain plain Elixir behind these actions. Runtime
  callers should resolve action names or modules through this registry before
  invoking work.
  """

  alias AllbertAssist.Actions.Capability
  alias AllbertAssist.Actions.Confirmations.ApproveConfirmation
  alias AllbertAssist.Actions.Confirmations.DenyConfirmation
  alias AllbertAssist.Actions.Confirmations.ExpireConfirmations
  alias AllbertAssist.Actions.Confirmations.ListConfirmations
  alias AllbertAssist.Actions.Confirmations.ShowConfirmation
  alias AllbertAssist.Actions.Intent.ActivateSkill
  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill
  alias AllbertAssist.Actions.Intent.RunShellCommand
  alias AllbertAssist.Actions.Security.Status, as: SecurityStatus
  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.ReadSetting
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Actions.Settings.UpdateSetting
  alias AllbertAssist.Actions.Skills.CreateSkill
  alias AllbertAssist.Actions.Skills.ValidateSkill
  alias AllbertAssist.Actions.Trace.RecordTrace

  @agent_actions [
    DirectAnswer,
    AppendMemory,
    ReadRecentMemory,
    ListSkills,
    ReadSkill,
    ActivateSkill,
    PlanShellCommand,
    RunShellCommand,
    ExternalNetworkRequest,
    ListSettings,
    ReadSetting,
    UpdateSetting,
    ExplainSetting,
    ListProviderProfiles,
    ListModelProfiles,
    SetProviderCredential
  ]

  @internal_actions [
    ValidateSkill,
    CreateSkill,
    SecurityStatus,
    ListConfirmations,
    ShowConfirmation,
    ApproveConfirmation,
    DenyConfirmation,
    ExpireConfirmations,
    RecordTrace
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
      notes:
        "v0.08 Level 1 local process execution; creates a durable confirmation before running."
    },
    ExternalNetworkRequest => %{
      permission: :external_network,
      exposure: :agent,
      execution_mode: :external_network_unavailable,
      skill_backed?: true,
      confirmation: :future_confirmation_required,
      notes: "Reports confirmation need only; no network adapter executes in v0.06."
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
    RecordTrace => %{
      permission: :memory_write,
      exposure: :internal,
      execution_mode: :internal_trace,
      skill_backed?: false,
      confirmation: :not_required
    }
  }

  @doc "Return registered runtime action modules in stable display order."
  @spec modules() :: nonempty_list(module())
  def modules, do: @actions

  @doc "Return action modules that can be exposed to the intent agent."
  @spec agent_modules() :: nonempty_list(module())
  def agent_modules, do: @agent_actions

  @doc "Return registered action names in stable display order."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@actions, & &1.name())

  @doc "Return canonical capability metadata for all registered actions."
  @spec capabilities() :: [Capability.t()]
  def capabilities, do: Enum.map(@actions, &capability_for_module!/1)

  @doc "Return canonical capability metadata for intent-agent actions."
  @spec agent_capabilities() :: [Capability.t()]
  def agent_capabilities, do: Enum.map(@agent_actions, &capability_for_module!/1)

  @doc "Return canonical capability metadata for internal-only actions."
  @spec internal_capabilities() :: [Capability.t()]
  def internal_capabilities, do: Enum.map(@internal_actions, &capability_for_module!/1)

  @doc "Resolve a registered action by module, string name, or atom name."
  @spec resolve(module() | String.t() | atom()) ::
          {:ok, module()} | {:error, {:unknown_action, term()}}
  def resolve(action) when is_atom(action) and action in @actions, do: {:ok, action}

  def resolve(action) when is_atom(action) do
    action
    |> Atom.to_string()
    |> String.replace_prefix("Elixir.", "")
    |> resolve_name(action)
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

  @doc "Return true when the module is registered for runtime invocation."
  @spec registered_module?(module()) :: boolean()
  def registered_module?(module), do: module in @actions

  @doc "Return duplicate registered names. This should always be empty."
  @spec duplicate_names() :: [String.t()]
  def duplicate_names do
    names()
    |> Enum.frequencies()
    |> Enum.filter(fn {_name, count} -> count > 1 end)
    |> Enum.map(fn {name, _count} -> name end)
  end

  defp resolve_name(name, original) do
    normalized = normalize_name(name)

    case Enum.find(@actions, &(normalize_name(&1.name()) == normalized)) do
      nil -> {:error, {:unknown_action, original}}
      module -> {:ok, module}
    end
  end

  defp capability_for_module!(module) do
    attrs = Map.fetch!(@capability_attrs, module)
    Capability.new(module, attrs)
  end

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
