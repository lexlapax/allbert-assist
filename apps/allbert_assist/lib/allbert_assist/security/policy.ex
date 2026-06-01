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
    dynamic_codegen_request: "permissions.dynamic_codegen_request",
    dynamic_codegen_discard: "permissions.dynamic_codegen_discard",
    skill_script_execute: "permissions.skill_script_execute",
    confirmation_decide: "permissions.confirmation_decide",
    objective_write: "permissions.objective_write",
    workspace_canvas_write: "permissions.workspace_canvas_write",
    sandbox_trial: "permissions.sandbox_trial",
    dynamic_integration: "permissions.dynamic_integration",
    stocksage_write: "permissions.stocksage_write",
    stocksage_analyze: "permissions.stocksage_analyze",
    stocksage_evidence_fetch: "permissions.stocksage_evidence_fetch",
    notes_file_write: "permissions.notes_file_write",
    tool_discovery: "permissions.tool_discovery",
    mcp_server_connect: "permissions.mcp_server_connect",
    mcp_tool_call: "permissions.mcp_tool_call",
    mcp_resource_read: "permissions.mcp_resource_read",
    browser_session_start: "permissions.browser_session_start",
    browser_navigate: "permissions.browser_navigate",
    browser_extract: "permissions.browser_extract",
    browser_screenshot: "permissions.browser_screenshot",
    browser_interact: "permissions.browser_interact",
    browser_form_fill: "permissions.browser_form_fill",
    browser_download: "permissions.browser_download",
    workflow_read: "permissions.workflow_read",
    workflow_run_start: "permissions.workflow_run_start",
    plan_cancel: "permissions.plan_cancel"
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
    dynamic_codegen_request: :allowed,
    dynamic_codegen_discard: :allowed,
    skill_script_execute: :denied,
    confirmation_decide: :allowed,
    objective_write: :allowed,
    workspace_canvas_write: :allowed,
    sandbox_trial: :allowed,
    dynamic_integration: :needs_confirmation,
    stocksage_write: :allowed,
    stocksage_analyze: :needs_confirmation,
    stocksage_evidence_fetch: :allowed,
    notes_file_write: :needs_confirmation,
    tool_discovery: :allowed,
    mcp_server_connect: :needs_confirmation,
    mcp_tool_call: :needs_confirmation,
    mcp_resource_read: :allowed,
    browser_session_start: :needs_confirmation,
    browser_navigate: :needs_confirmation,
    browser_extract: :allowed,
    browser_screenshot: :allowed,
    browser_interact: :needs_confirmation,
    browser_form_fill: :denied,
    browser_download: :denied,
    workflow_read: :allowed,
    workflow_run_start: :needs_confirmation,
    plan_cancel: :allowed,
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
          | :dynamic_codegen_request
          | :dynamic_codegen_discard
          | :skill_script_execute
          | :confirmation_decide
          | :objective_write
          | :workspace_canvas_write
          | :sandbox_trial
          | :dynamic_integration
          | :stocksage_write
          | :stocksage_analyze
          | :stocksage_evidence_fetch
          | :notes_file_write
          | :tool_discovery
          | :mcp_server_connect
          | :mcp_tool_call
          | :mcp_resource_read
          | :browser_session_start
          | :browser_navigate
          | :browser_extract
          | :browser_screenshot
          | :browser_interact
          | :browser_form_fill
          | :browser_download
          | :workflow_read
          | :workflow_run_start
          | :plan_cancel
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
      :dynamic_codegen_request,
      :dynamic_codegen_discard,
      :skill_script_execute,
      :confirmation_decide,
      :objective_write,
      :workspace_canvas_write,
      :sandbox_trial,
      :dynamic_integration,
      :stocksage_write,
      :stocksage_analyze,
      :stocksage_evidence_fetch,
      :notes_file_write,
      :tool_discovery,
      :mcp_server_connect,
      :mcp_tool_call,
      :mcp_resource_read,
      :browser_session_start,
      :browser_navigate,
      :browser_extract,
      :browser_screenshot,
      :browser_interact,
      :browser_form_fill,
      :browser_download,
      :workflow_read,
      :workflow_run_start,
      :plan_cancel,
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

    final_effective =
      effective_decision(permission, context, configured, effective, context_denial)

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

  defp effective_decision(_permission, _context, _configured, _effective, context_denial)
       when is_binary(context_denial),
       do: :denied

  defp effective_decision(permission, context, %{decision: decision}, effective, _context_denial)
       when decision != :denied do
    cond do
      advisory_memory_write?(permission, context) -> :needs_confirmation
      approved_parent_analysis?(permission, context) -> :allowed
      fixture_evidence?(permission, context) -> :allowed
      true -> effective
    end
  end

  defp effective_decision(_permission, _context, _configured, effective, _context_denial),
    do: effective

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
  def safety_floor(:dynamic_integration), do: :needs_confirmation
  def safety_floor(:mcp_server_connect), do: :needs_confirmation
  def safety_floor(:mcp_tool_call), do: :needs_confirmation
  def safety_floor(:browser_session_start), do: :needs_confirmation
  def safety_floor(:browser_navigate), do: :needs_confirmation
  def safety_floor(:browser_interact), do: :needs_confirmation
  def safety_floor(:browser_form_fill), do: :needs_confirmation
  def safety_floor(:browser_download), do: :needs_confirmation
  def safety_floor(:workflow_run_start), do: :needs_confirmation
  def safety_floor(:stocksage_analyze), do: :needs_confirmation
  def safety_floor(:stocksage_evidence_fetch), do: :needs_confirmation
  def safety_floor(:notes_file_write), do: :needs_confirmation
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

  defp advisory_memory_write?(:memory_write, %{advisory: %{present?: true}}), do: true
  defp advisory_memory_write?(_permission, _context), do: false

  defp approved_parent_analysis?(:stocksage_evidence_fetch, %{parent: parent})
       when is_map(parent) do
    Map.get(parent, :permission) in [:stocksage_analyze, "stocksage_analyze"] and
      Map.get(parent, :approved?) == true
  end

  defp approved_parent_analysis?(_permission, _context), do: false

  defp fixture_evidence?(:stocksage_evidence_fetch, %{resource: %{kind: kind}})
       when kind in [:fixture_evidence, "fixture_evidence"],
       do: true

  defp fixture_evidence?(_permission, _context), do: false

  defp reason(:read_only, :allowed, _configured, _floor, _context),
    do: "Read-only inspection is allowed locally."

  defp reason(:memory_write, :allowed, _configured, _floor, _context),
    do: "Memory-write intent is allowed for markdown memory."

  defp reason(:memory_write, :needs_confirmation, _configured, _floor, %{
         advisory: %{present?: true}
       }),
       do:
         "Advisory provider output requires explicit operator confirmation before durable memory writes."

  defp reason(:command_plan, :allowed, _configured, _floor, _context),
    do: "Planning shell work is allowed when no command executes."

  defp reason(:command_execute, :denied, _configured, _floor, _context),
    do: "Command execution is denied until local execution is explicitly enabled and confirmed."

  defp reason(:external_network, :needs_confirmation, _configured, _floor, _context),
    do: "External network access requires confirmation and a configured v0.10 adapter."

  defp reason(:browser_session_start, :needs_confirmation, _configured, _floor, _context),
    do: "Starting a browser session requires explicit operator confirmation."

  defp reason(:browser_navigate, :needs_confirmation, _configured, _floor, _context),
    do: "Browser navigation requires confirmation or a matching remembered domain grant."

  defp reason(:browser_extract, :allowed, _configured, _floor, _context),
    do: "Bounded extraction from an already-loaded browser page is allowed."

  defp reason(:browser_screenshot, :allowed, _configured, _floor, _context),
    do: "Bounded browser screenshots are allowed with credential-input redaction."

  defp reason(:browser_interact, :needs_confirmation, _configured, _floor, _context),
    do: "Browser interaction can change page state and requires confirmation."

  defp reason(:browser_form_fill, :denied, _configured, _floor, _context),
    do: "Browser form fill is denied by default."

  defp reason(:browser_form_fill, :needs_confirmation, _configured, _floor, _context),
    do: "Browser form fill requires explicit opt-in and confirmation."

  defp reason(:browser_download, :denied, _configured, _floor, _context),
    do: "Browser download is denied by default."

  defp reason(:browser_download, :needs_confirmation, _configured, _floor, _context),
    do: "Browser download requires explicit opt-in and confirmation."

  defp reason(:workflow_read, :allowed, _configured, _floor, _context),
    do: "Workflow YAML inspection and expansion are local read-only operations."

  defp reason(:workflow_read, :needs_confirmation, _configured, _floor, _context),
    do: "Workflow YAML reads require confirmation by current policy."

  defp reason(:workflow_read, :denied, _configured, _floor, _context),
    do: "Workflow YAML reads are denied by current policy."

  defp reason(:workflow_run_start, :needs_confirmation, _configured, _floor, _context),
    do: "Starting a plan run requires explicit operator confirmation."

  defp reason(:workflow_run_start, :denied, _configured, _floor, _context),
    do: "Starting a plan run is denied by current policy."

  defp reason(:plan_cancel, :allowed, _configured, _floor, _context),
    do: "Cooperative plan cancellation is allowed through registered Plan/Build actions."

  defp reason(:plan_cancel, :needs_confirmation, _configured, _floor, _context),
    do: "Cooperative plan cancellation requires confirmation by current policy."

  defp reason(:plan_cancel, :denied, _configured, _floor, _context),
    do: "Cooperative plan cancellation is denied by current policy."

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

  defp reason(:dynamic_codegen_request, :allowed, _configured, _floor, _context),
    do: "Explicit dynamic draft requests are allowed through the codegen request action."

  defp reason(:dynamic_codegen_request, :denied, _configured, _floor, _context),
    do: "Dynamic draft requests are denied by current policy."

  defp reason(:dynamic_codegen_discard, :allowed, _configured, _floor, _context),
    do: "Dynamic draft discard is allowed for non-integrated draft lifecycle cleanup."

  defp reason(:dynamic_codegen_discard, :denied, _configured, _floor, _context),
    do: "Dynamic draft discard is denied by current policy."

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

  defp reason(:workspace_canvas_write, :allowed, _configured, _floor, _context),
    do: "Workspace canvas writes are allowed through registered workspace actions."

  defp reason(:workspace_canvas_write, :denied, _configured, _floor, _context),
    do: "Workspace canvas writes are denied by current policy."

  defp reason(:sandbox_trial, :allowed, _configured, _floor, _context),
    do:
      "Sandbox trial execution is allowed only through default-off sandbox settings and registered sandbox actions."

  defp reason(:sandbox_trial, :denied, _configured, _floor, _context),
    do: "Sandbox trial execution is denied by current policy."

  defp reason(:dynamic_integration, :needs_confirmation, _configured, _floor, _context),
    do:
      "Dynamic integration hot-loads reviewed code into the core node and requires operator confirmation."

  defp reason(:dynamic_integration, :denied, _configured, _floor, _context),
    do: "Dynamic integration is denied by current policy."

  defp reason(:stocksage_write, :allowed, _configured, _floor, _context),
    do: "Local StockSage domain writes are allowed through registered StockSage actions."

  defp reason(:stocksage_analyze, :needs_confirmation, _configured, _floor, _context),
    do:
      "StockSage analysis execution requires confirmation; the Python bridge makes external market-data calls."

  defp reason(:stocksage_analyze, :denied, _configured, _floor, _context),
    do: "StockSage analysis execution is denied by current policy."

  defp reason(:stocksage_evidence_fetch, :allowed, _configured, _floor, _context),
    do: "StockSage evidence fetch is allowed inside an approved StockSage analysis run."

  defp reason(:stocksage_evidence_fetch, :needs_confirmation, _configured, _floor, _context),
    do:
      "StockSage evidence fetch requires Resource Access confirmation outside an approved analysis run."

  defp reason(:stocksage_evidence_fetch, :denied, _configured, _floor, _context),
    do: "StockSage evidence fetch is denied by current policy."

  defp reason(:tool_discovery, :allowed, _configured, _floor, _context),
    do: "Tool discovery search is allowed through registered discovery actions."

  defp reason(:tool_discovery, :denied, _configured, _floor, _context),
    do: "Tool discovery search is denied by current policy."

  defp reason(:mcp_server_connect, :needs_confirmation, _configured, _floor, _context),
    do: "Connecting discovered MCP servers requires explicit operator confirmation."

  defp reason(:mcp_server_connect, :denied, _configured, _floor, _context),
    do: "Connecting discovered MCP servers is denied by current policy."

  defp reason(:mcp_tool_call, :needs_confirmation, _configured, _floor, _context),
    do: "MCP tool calls require explicit operator confirmation."

  defp reason(:mcp_tool_call, :denied, _configured, _floor, _context),
    do: "MCP tool calls are denied by current policy."

  defp reason(:mcp_resource_read, :allowed, _configured, _floor, _context),
    do: "MCP resource reads are allowed through registered MCP resource actions."

  defp reason(:mcp_resource_read, :needs_confirmation, _configured, _floor, _context),
    do: "MCP resource reads require operator confirmation by current policy."

  defp reason(:mcp_resource_read, :denied, _configured, _floor, _context),
    do: "MCP resource reads are denied by current policy."

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
