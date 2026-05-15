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
  def tier(:confirmation_decide), do: :medium
  def tier(:stocksage_write), do: :low
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
  defp reasons(:confirmation_decide, _tier, _context), do: ["operator confirmation decision"]
  defp reasons(:stocksage_write, _tier, _context), do: ["local StockSage SQLite domain write"]
  defp reasons(:skill_script_execute, _tier, _context), do: ["trusted skill script execution"]
  defp reasons(:settings_secret_write, _tier, _context), do: ["encrypted credential write"]
  defp reasons(:external_network, _tier, _context), do: ["confirmed external network boundary"]
  defp reasons(:package_install, _tier, _context), do: ["package manager process boundary"]
  defp reasons(:online_skill_import, _tier, _context), do: ["remote skill import boundary"]
  defp reasons(:command_execute, _tier, _context), do: ["shell/process execution boundary"]
  defp reasons(:settings_secret_read, _tier, _context), do: ["raw secret read attempt"]
  defp reasons(_permission, _tier, _context), do: ["unknown permission class"]
end
