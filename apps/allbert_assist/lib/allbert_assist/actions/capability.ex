defmodule AllbertAssist.Actions.Capability do
  @moduledoc """
  Canonical action capability metadata for registered Allbert actions.

  This is descriptive metadata used by skill contract validation and operator
  traces. It does not execute actions and does not grant permission.
  """

  @enforce_keys [
    :name,
    :module,
    :permission,
    :exposure,
    :execution_mode,
    :skill_backed?
  ]
  defstruct [
    :name,
    :module,
    :permission,
    :exposure,
    :execution_mode,
    :skill_backed?,
    confirmation: nil,
    notes: nil
  ]

  @type exposure :: :agent | :internal
  @type execution_mode ::
          :read_only
          | :memory_write
          | :command_plan_only
          | :external_network_unavailable
          | :settings_read
          | :settings_write
          | :skill_validation
          | :skill_write
          | :secret_write
          | :security_status
          | :internal_trace

  @type t :: %__MODULE__{
          name: String.t(),
          module: module(),
          permission: atom(),
          exposure: exposure(),
          execution_mode: execution_mode(),
          skill_backed?: boolean(),
          confirmation: nil | atom(),
          notes: nil | String.t()
        }

  @doc "Build capability metadata from a registered Jido action module."
  @spec new(module(), map()) :: t()
  def new(module, attrs) when is_atom(module) and is_map(attrs) do
    %__MODULE__{
      name: module.name(),
      module: module,
      permission: Map.fetch!(attrs, :permission),
      exposure: Map.fetch!(attrs, :exposure),
      execution_mode: Map.fetch!(attrs, :execution_mode),
      skill_backed?: Map.fetch!(attrs, :skill_backed?),
      confirmation: Map.get(attrs, :confirmation),
      notes: Map.get(attrs, :notes)
    }
  end

  @doc "Return compact, trace-safe capability metadata."
  @spec summary(t()) :: map()
  def summary(%__MODULE__{} = capability) do
    %{
      name: capability.name,
      module: capability.module,
      registered?: true,
      permission: capability.permission,
      exposure: capability.exposure,
      execution_mode: capability.execution_mode,
      skill_backed?: capability.skill_backed?,
      confirmation: capability.confirmation
    }
  end
end
