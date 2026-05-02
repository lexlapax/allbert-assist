defmodule AllbertAssist.Security.Policy do
  @moduledoc """
  Settings-backed policy lookup with v0.05 built-in safety floors.
  """

  alias AllbertAssist.Settings

  @permission_settings %{
    memory_write: "permissions.memory_write",
    command_plan: "permissions.command_plan",
    command_execute: "permissions.command_execute",
    external_network: "permissions.external_network",
    settings_write: "permissions.settings_write"
  }

  @default_decisions %{
    read_only: :allowed,
    memory_write: :allowed,
    command_plan: :allowed,
    command_execute: :denied,
    external_network: :needs_confirmation,
    settings_write: :allowed,
    settings_secret_write: :allowed,
    settings_secret_read: :denied
  }

  @known_permissions Map.keys(@default_decisions)

  @doc "Return known permission classes in stable order."
  @spec permission_classes() :: [atom()]
  def permission_classes do
    [
      :read_only,
      :memory_write,
      :command_plan,
      :command_execute,
      :external_network,
      :settings_write,
      :settings_secret_write,
      :settings_secret_read
    ]
  end

  @doc "Resolve effective policy for a permission and normalized context."
  @spec resolve(atom(), map()) :: map()
  def resolve(permission, context \\ %{}) do
    configured = configured_policy(permission)
    floor = safety_floor(permission)
    effective = apply_safety_floor(configured.decision, floor)

    %{
      permission: permission,
      setting_key: Map.get(@permission_settings, permission),
      configured: configured.value,
      configured_decision: configured.decision,
      effective: effective,
      source: configured.source,
      safety_floor: floor,
      capped?: effective != configured.decision,
      reason: reason(permission, effective, configured, floor, context)
    }
  end

  @doc "Return configured and effective policies for status surfaces."
  @spec permission_policies(map()) :: [map()]
  def permission_policies(context \\ %{}) do
    Enum.map(permission_classes(), &resolve(&1, context))
  end

  @doc "Return the v0.05 safety floor for a permission."
  @spec safety_floor(atom()) :: :allowed | :needs_confirmation | :denied
  def safety_floor(:command_execute), do: :denied
  def safety_floor(:external_network), do: :needs_confirmation
  def safety_floor(:settings_secret_read), do: :denied
  def safety_floor(permission) when permission in @known_permissions, do: :allowed
  def safety_floor(_permission), do: :denied

  defp configured_policy(permission) do
    setting_key = Map.get(@permission_settings, permission)

    with key when is_binary(key) <- setting_key,
         {:ok, value} <- Settings.get(key) do
      %{
        value: value,
        decision: normalize_setting_value(value, default_decision(permission)),
        source: :settings
      }
    else
      _other ->
        %{
          value: nil,
          decision: default_decision(permission),
          source: :built_in_default
        }
    end
  rescue
    _exception ->
      %{
        value: nil,
        decision: default_decision(permission),
        source: :built_in_default
      }
  end

  defp default_decision(permission), do: Map.get(@default_decisions, permission, :denied)

  defp normalize_setting_value("allowed", _default), do: :allowed
  defp normalize_setting_value("allowed_safe_keys", _default), do: :allowed
  defp normalize_setting_value("needs_confirmation", _default), do: :needs_confirmation
  defp normalize_setting_value("denied", _default), do: :denied
  defp normalize_setting_value(_value, default), do: default

  defp apply_safety_floor(:denied, _floor), do: :denied
  defp apply_safety_floor(_configured, :denied), do: :denied
  defp apply_safety_floor(:allowed, :needs_confirmation), do: :needs_confirmation
  defp apply_safety_floor(configured, _floor), do: configured

  defp reason(:read_only, :allowed, _configured, _floor, _context),
    do: "Read-only inspection is allowed locally."

  defp reason(:memory_write, :allowed, _configured, _floor, _context),
    do: "Memory-write intent is allowed for markdown memory."

  defp reason(:command_plan, :allowed, _configured, _floor, _context),
    do: "Planning shell work is allowed when no command executes."

  defp reason(:command_execute, :denied, _configured, _floor, _context),
    do: "Command execution is denied until the v0.08 sandbox milestone."

  defp reason(:external_network, :needs_confirmation, _configured, _floor, _context),
    do: "External network access requires confirmation and has no execution adapter in v0.05."

  defp reason(:settings_write, :allowed, _configured, _floor, _context),
    do: "Safe Settings Central writes are allowed through registered settings actions."

  defp reason(:settings_secret_write, :allowed, _configured, _floor, _context),
    do: "Provider credentials may be configured through explicit credential flows."

  defp reason(:settings_secret_read, :denied, _configured, _floor, _context),
    do: "Raw secret display is not available from user-facing settings surfaces."

  defp reason(permission, :denied, _configured, _floor, _context),
    do: "Unknown or disabled permission class: #{inspect(permission)}."

  defp reason(permission, :needs_confirmation, _configured, _floor, _context),
    do: "Permission requires confirmation before it can run: #{inspect(permission)}."

  defp reason(permission, :allowed, _configured, _floor, _context),
    do: "Permission is allowed by current policy: #{inspect(permission)}."
end
