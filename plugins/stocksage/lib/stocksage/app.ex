defmodule StockSage.App do
  @moduledoc """
  Allbert app contract implementation for StockSage.

  v0.20 registers StockSage as a real app with no concrete web surfaces yet.
  v0.27 (formerly v0.25) fills in LiveView route surfaces through the same
  provider behaviour.
  """

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  @impl true
  def app_id, do: :stocksage

  @impl true
  def display_name, do: "StockSage"

  @impl true
  # v0.25 closeout: release-pinned with the native financial specialist-agent
  # graph, explicit Python parity, and delegate-agent proof.
  # Convention is documented in DEVELOPMENT.md "App version metadata".
  def version, do: "0.25.0"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def actions, do: StockSage.Plugin.actions()

  @impl AllbertAssist.App
  def skill_paths, do: StockSage.Plugin.skill_paths()

  @impl AllbertAssist.App
  def surfaces, do: []

  def surface_catalog, do: []
end
