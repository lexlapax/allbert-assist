defmodule AllbertAssist.Skills.CapabilityContract do
  @moduledoc """
  Inert v0.03 capability contract parsed from Allbert skill metadata.

  The contract is descriptive until v0.04. It never grants permission or causes
  an action to execute by itself.
  """

  defstruct status: :none,
            actions: [],
            permissions: [],
            confirmation: nil,
            memory_effects: [],
            trace_effects: [],
            raw: %{}

  @type status :: :none | :draft | :legacy

  @type t :: %__MODULE__{
          status: status(),
          actions: [String.t()],
          permissions: [String.t()],
          confirmation: nil | String.t(),
          memory_effects: [String.t()],
          trace_effects: [String.t()],
          raw: map()
        }

  @doc "Build a draft contract from parsed `metadata.allbert.*` fields."
  @spec from_metadata(map()) :: t()
  def from_metadata(metadata) when is_map(metadata) do
    actions = list_value(metadata["allbert.actions"])
    permissions = list_value(metadata["allbert.permissions"])

    %__MODULE__{
      status: contract_status(actions, permissions),
      actions: actions,
      permissions: permissions,
      confirmation: string_value(metadata["allbert.confirmation"]),
      memory_effects: list_value(metadata["allbert.memory-effects"]),
      trace_effects: list_value(metadata["allbert.trace-effects"]),
      raw: metadata
    }
  end

  def from_metadata(_metadata), do: %__MODULE__{}

  @doc "Build a legacy bridge contract for pre-M4 built-in declarations."
  @spec legacy(String.t(), atom()) :: t()
  def legacy(action_name, permission) when is_binary(action_name) do
    %__MODULE__{
      status: :legacy,
      actions: [action_name],
      permissions: [to_string(permission)],
      raw: %{"allbert.actions" => action_name, "allbert.permissions" => to_string(permission)}
    }
  end

  defp contract_status([], []), do: :none
  defp contract_status(_actions, _permissions), do: :draft

  defp string_value(value) when is_binary(value), do: value
  defp string_value(_value), do: nil

  defp list_value(nil), do: []

  defp list_value(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_value(values) when is_list(values) do
    values
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp list_value(value), do: [to_string(value)]
end
