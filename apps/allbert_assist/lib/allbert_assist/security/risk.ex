defmodule AllbertAssist.Security.Risk do
  @moduledoc """
  Risk-tier vocabulary for Security Central decisions.
  """

  @type tier :: :minimal | :low | :medium | :high | :critical

  @doc "Classify a permission and normalized context into a risk summary."
  @spec classify(atom(), map()) :: map()
  def classify(permission, context \\ %{}) do
    tier = tier(permission)

    %{
      tier: tier,
      reasons: reasons(permission, tier, context)
    }
  end

  @doc "Return the default risk tier for a permission."
  @spec tier(atom()) :: tier()
  def tier(:read_only), do: :minimal
  def tier(:memory_write), do: :low
  def tier(:command_plan), do: :low
  def tier(:settings_write), do: :medium
  def tier(:skill_write), do: :medium
  def tier(:dynamic_codegen_request), do: :medium
  def tier(:dynamic_codegen_discard), do: :medium
  def tier(:confirmation_decide), do: :medium
  def tier(:objective_write), do: :low
  def tier(:workspace_canvas_write), do: :low
  def tier(:sandbox_trial), do: :high
  def tier(:dynamic_integration), do: :critical
  def tier(:stocksage_write), do: :low
  def tier(:stocksage_analyze), do: :high
  def tier(:stocksage_evidence_fetch), do: :medium
  def tier(:tool_discovery), do: :medium
  def tier(:mcp_server_connect), do: :high
  def tier(:mcp_tool_call), do: :high
  def tier(:mcp_resource_read), do: :medium
  def tier(:browser_session_start), do: :high
  def tier(:browser_navigate), do: :high
  def tier(:browser_extract), do: :medium
  def tier(:browser_screenshot), do: :medium
  def tier(:browser_interact), do: :high
  def tier(:browser_form_fill), do: :high
  def tier(:browser_download), do: :high
  def tier(:workflow_read), do: :low
  def tier(:workflow_run_start), do: :high
  def tier(:plan_cancel), do: :low
  def tier(:skill_script_execute), do: :high
  def tier(:settings_secret_write), do: :high
  def tier(:external_network), do: :high
  def tier(:package_install), do: :high
  def tier(:online_skill_import), do: :high
  def tier(:command_execute), do: :high
  def tier(:settings_secret_read), do: :critical
  def tier(_permission), do: :critical

  defp reasons(:read_only, _tier, _context), do: ["local read-only inspection"]
  defp reasons(:memory_write, _tier, _context), do: ["durable markdown memory write"]
  defp reasons(:command_plan, _tier, _context), do: ["non-executing command planning"]
  defp reasons(:settings_write, _tier, _context), do: ["operator-visible settings change"]
  defp reasons(:skill_write, _tier, _context), do: ["local skill scaffold write"]

  defp reasons(:dynamic_codegen_request, _tier, _context),
    do: ["LLM-backed dynamic source draft request"]

  defp reasons(:dynamic_codegen_discard, _tier, _context),
    do: ["dynamic source draft lifecycle discard"]

  defp reasons(:confirmation_decide, _tier, _context), do: ["operator confirmation decision"]
  defp reasons(:objective_write, _tier, _context), do: ["local objective lifecycle write"]
  defp reasons(:workspace_canvas_write, _tier, _context), do: ["local workspace canvas write"]
  defp reasons(:sandbox_trial, _tier, _context), do: ["default-off container sandbox trial"]
  defp reasons(:dynamic_integration, _tier, _context), do: ["confirmed dynamic code integration"]
  defp reasons(:stocksage_write, _tier, _context), do: ["local StockSage SQLite domain write"]

  defp reasons(:stocksage_analyze, _tier, _context),
    do: ["StockSage Python bridge analysis execution with external market-data calls"]

  defp reasons(:stocksage_evidence_fetch, _tier, _context),
    do: ["StockSage bounded external evidence provider call"]

  defp reasons(:tool_discovery, _tier, _context),
    do: ["read-only MCP registry discovery egress"]

  defp reasons(:mcp_server_connect, _tier, _context),
    do: ["confirmed MCP server configuration write"]

  defp reasons(:mcp_tool_call, _tier, _context),
    do: ["confirmed MCP server tool execution"]

  defp reasons(:mcp_resource_read, _tier, _context),
    do: ["MCP server resource read boundary"]

  defp reasons(:browser_session_start, _tier, _context),
    do: ["browser driver session lifecycle boundary"]

  defp reasons(:browser_navigate, _tier, _context),
    do: ["confirmed browser navigation and remote page execution boundary"]

  defp reasons(:browser_extract, _tier, _context),
    do: ["bounded browser page/document extraction"]

  defp reasons(:browser_screenshot, _tier, _context),
    do: ["bounded browser screenshot capture"]

  defp reasons(:browser_interact, _tier, _context), do: ["confirmed browser interaction"]
  defp reasons(:browser_form_fill, _tier, _context), do: ["credential-bearing browser form fill"]
  defp reasons(:browser_download, _tier, _context), do: ["browser download boundary"]
  defp reasons(:workflow_read, _tier, _context), do: ["local workflow YAML read and expansion"]
  defp reasons(:workflow_run_start, _tier, _context), do: ["confirmed plan run start boundary"]
  defp reasons(:plan_cancel, _tier, _context), do: ["cooperative objective cancellation"]

  defp reasons(:skill_script_execute, _tier, _context), do: ["trusted skill script execution"]
  defp reasons(:settings_secret_write, _tier, _context), do: ["encrypted credential write"]
  defp reasons(:external_network, _tier, _context), do: ["confirmed external network boundary"]
  defp reasons(:package_install, _tier, _context), do: ["package manager process boundary"]
  defp reasons(:online_skill_import, _tier, _context), do: ["remote skill import boundary"]
  defp reasons(:command_execute, _tier, _context), do: ["shell/process execution boundary"]
  defp reasons(:settings_secret_read, _tier, _context), do: ["raw secret read attempt"]
  defp reasons(_permission, _tier, _context), do: ["unknown permission class"]
end
