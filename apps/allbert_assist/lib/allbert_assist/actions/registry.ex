defmodule AllbertAssist.Actions.Registry do
  @moduledoc """
  Canonical registry for Allbert runtime-facing Jido actions.

  Pure domain modules can remain plain Elixir behind these actions. Runtime
  callers should resolve action names or modules through this registry before
  invoking work.
  """

  alias AllbertAssist.Actions.Intent.ActivateSkill
  alias AllbertAssist.Actions.Intent.AppendMemory
  alias AllbertAssist.Actions.Intent.DirectAnswer
  alias AllbertAssist.Actions.Intent.ExternalNetworkRequest
  alias AllbertAssist.Actions.Intent.ListSkills
  alias AllbertAssist.Actions.Intent.PlanShellCommand
  alias AllbertAssist.Actions.Intent.ReadRecentMemory
  alias AllbertAssist.Actions.Intent.ReadSkill
  alias AllbertAssist.Actions.Settings.ExplainSetting
  alias AllbertAssist.Actions.Settings.ListModelProfiles
  alias AllbertAssist.Actions.Settings.ListProviderProfiles
  alias AllbertAssist.Actions.Settings.ListSettings
  alias AllbertAssist.Actions.Settings.ReadSetting
  alias AllbertAssist.Actions.Settings.SetProviderCredential
  alias AllbertAssist.Actions.Settings.UpdateSetting
  alias AllbertAssist.Actions.Security.Status, as: SecurityStatus
  alias AllbertAssist.Actions.Trace.RecordTrace

  @agent_actions [
    DirectAnswer,
    AppendMemory,
    ReadRecentMemory,
    ListSkills,
    ReadSkill,
    ActivateSkill,
    PlanShellCommand,
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
    SecurityStatus,
    RecordTrace
  ]

  @actions @agent_actions ++ @internal_actions

  @doc "Return registered runtime action modules in stable display order."
  @spec modules() :: nonempty_list(module())
  def modules, do: @actions

  @doc "Return action modules that can be exposed to the intent agent."
  @spec agent_modules() :: nonempty_list(module())
  def agent_modules, do: @agent_actions

  @doc "Return registered action names in stable display order."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@actions, & &1.name())

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

  defp normalize_name(name) do
    name
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "_")
    |> String.trim("_")
  end
end
