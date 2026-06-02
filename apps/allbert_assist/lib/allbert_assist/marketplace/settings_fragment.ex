defmodule AllbertAssist.Marketplace.SettingsFragment do
  @moduledoc """
  Marketplace Settings Central fragment facade.

  Core settings fragments are assembled from `AllbertAssist.Settings.Schema`.
  This module gives Marketplace code and tests a stable namespace-local way to
  retrieve the generated core fragment without adding a second registry path.
  """

  alias AllbertAssist.Settings.Fragments

  @spec namespace() :: String.t()
  def namespace, do: "marketplace"

  @spec fragment() :: {:ok, AllbertAssist.Settings.Fragment.t()} | {:error, :not_found}
  def fragment, do: Fragments.fragment_for_key("marketplace.enabled")
end
