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
    package_install: "permissions.package_install",
    online_skill_import: "permissions.online_skill_import",
    settings_write: "permissions.settings_write",
    skill_write: "permissions.skill_write",
    skill_script_execute: "permissions.skill_script_execute",
    confirmation_decide: "permissions.confirmation_decide",
    objective_write: "permissions.objective_write",
    stocksage_write: "permissions.stocksage_write",
    stocksage_analyze: "permissions.stocksage_analyze"
  }

  @default_decisions %{
    read_only: :allowed,
    memory_write: :allowed,
    command_plan: :allowed,
    command_execute: :denied,
    external_network: :needs_confirmation,
    package_install: :denied,
    online_skill_import: :denied,
    settings_write: :allowed,
    skill_write: :allowed,
    skill_script_execute: :denied,
    confirmation_decide: :allowed,
    objective_write: :allowed,
    stocksage_write: :allowed,
    stocksage_analyze: :needs_confirmation,
    settings_secret_write: :allowed,
    settings_secret_read: :denied
  }

  @known_permissions Map.keys(@default_decisions)

  @type permission ::
          :read_only
          | :memory_write
          | :command_plan
          | :command_execute
          | :external_network
          | :package_install
          | :online_skill_import
          | :settings_write
          | :skill_write
          | :skill_script_execute
          | :confirmation_decide
          | :objective_write
          | :stocksage_write
          | :stocksage_analyze
          | :settings_secret_write
          | :settings_secret_read

  @doc "Return known permission classes in stable order."
  @spec permission_classes() :: nonempty_list(permission())
  def permission_classes do
    [
      :read_only,
      :memory_write,
      :command_plan,
      :command_execute,
      :external_network,
      :package_install,
      :online_skill_import,
      :settings_write,
      :skill_write,
      :skill_script_execute,
      :confirmation_decide,
      :objective_write,
      :stocksage_write,
      :stocksage_analyze,
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
    context_denial = context_denial(permission, context)
    final_effective = if context_denial, do: :denied, else: effective

    %{
      permission: permission,
      setting_key: Map.get(@permission_settings, permission),
      configured: configured.value,
      configured_decision: configured.decision,
      effective: final_effective,
      source: configured.source,
      safety_floor: floor,
      capped?: final_effective != configured.decision,
      context_denial: context_denial,
      reason: context_denial || reason(permission, final_effective, configured, floor, context)
    }
  end

  @doc "Return configured and effective policies for status surfaces."
  @spec permission_policies(map()) :: [map()]
  def permission_policies(context \\ %{}) do
    Enum.map(permission_classes(), &resolve(&1, context))
  end

  @doc "Return the v0.05 safety floor for a permission."
  @spec safety_floor(atom()) :: :allowed | :needs_confirmation | :denied
  def safety_floor(:command_execute), do: :needs_confirmation
  def safety_floor(:external_network), do: :needs_confirmation
  def safety_floor(:package_install), do: :needs_confirmation
  def safety_floor(:online_skill_import), do: :needs_confirmation
  def safety_floor(:skill_script_execute), do: :needs_confirmation
  def safety_floor(:stocksage_analyze), do: :needs_confirmation
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

  defp context_denial(_permission, %{action: %{name: name, registered?: false}})
       when not is_nil(name) do
    "Unknown or unregistered action boundary: #{inspect(name)}."
  end

  defp context_denial(permission, %{skill: %{lookup_status: :not_found, name: name}})
       when not is_nil(name) and permission != :read_only do
    "Selected skill is not trusted, enabled, or discoverable: #{inspect(name)}."
  end

  defp context_denial(permission, %{skill: %{trust_status: trust_status, name: name}})
       when not is_nil(name) and permission != :read_only and trust_status not in [nil, :trusted] do
    "Selected skill is not trusted for this permission: #{inspect(name)}."
  end

  defp context_denial(_permission, _context), do: nil

  defp reason(:read_only, :allowed, _configured, _floor, _context),
    do: "Read-only inspection is allowed locally."

  defp reason(:memory_write, :allowed, _configured, _floor, _context),
    do: "Memory-write intent is allowed for markdown memory."

  defp reason(:command_plan, :allowed, _configured, _floor, _context),
    do: "Planning shell work is allowed when no command executes."

  defp reason(:command_execute, :denied, _configured, _floor, _context),
    do: "Command execution is denied until local execution is explicitly enabled and confirmed."

  defp reason(:external_network, :needs_confirmation, _configured, _floor, _context),
    do: "External network access requires confirmation and a configured v0.10 adapter."

  defp reason(:package_install, :denied, _configured, _floor, _context),
    do: "Package installation is denied until an operator explicitly enables confirmed installs."

  defp reason(:package_install, :needs_confirmation, _configured, _floor, _context),
    do:
      "Package installation requires confirmation, sandbox settings, and package manager policy."

  defp reason(:online_skill_import, :denied, _configured, _floor, _context),
    do: "Online skill import is denied until an operator explicitly enables the import boundary."

  defp reason(:online_skill_import, :needs_confirmation, _configured, _floor, _context),
    do: "Online skill import requires confirmation, source audit, and disabled-by-default trust."

  defp reason(:settings_write, :allowed, _configured, _floor, _context),
    do: "Safe Settings Central writes are allowed through registered settings actions."

  defp reason(:skill_write, :allowed, _configured, _floor, _context),
    do: "Local skill scaffold writes are allowed through registered skill actions."

  defp reason(:skill_script_execute, :denied, _configured, _floor, _context),
    do: "Skill script execution is denied until explicitly enabled and confirmed."

  defp reason(:skill_script_execute, :needs_confirmation, _configured, _floor, _context),
    do: "Trusted skill script execution requires confirmation and resource digest checks."

  defp reason(:confirmation_decide, :allowed, _configured, _floor, _context),
    do: "Confirmation approval and denial are allowed for the local operator."

  defp reason(:objective_write, :allowed, _configured, _floor, _context),
    do: "Objective lifecycle writes are allowed through registered objective actions."

  defp reason(:objective_write, :denied, _configured, _floor, _context),
    do: "Objective lifecycle writes are denied by current policy."

  defp reason(:stocksage_write, :allowed, _configured, _floor, _context),
    do: "Local StockSage domain writes are allowed through registered StockSage actions."

  defp reason(:stocksage_analyze, :needs_confirmation, _configured, _floor, _context),
    do:
      "StockSage analysis execution requires confirmation; the Python bridge makes external market-data calls."

  defp reason(:stocksage_analyze, :denied, _configured, _floor, _context),
    do: "StockSage analysis execution is denied by current policy."

  defp reason(:settings_secret_write, :allowed, _configured, _floor, _context),
    do: "Provider credentials may be configured through explicit credential flows."

  defp reason(:settings_secret_read, :denied, _configured, _floor, _context),
    do: "Raw secret display is not available from user-facing settings surfaces."

  defp reason(permission, :denied, _configured, _floor, _context),
    do: "Unknown permission class: #{inspect(permission)}."

  defp reason(permission, :needs_confirmation, _configured, _floor, _context),
    do: "Permission requires confirmation before it can run: #{inspect(permission)}."

  defp reason(permission, :allowed, _configured, _floor, _context),
    do: "Permission is allowed by current policy: #{inspect(permission)}."
end
