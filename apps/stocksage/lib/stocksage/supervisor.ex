defmodule StockSage.Supervisor do
  @moduledoc """
  StockSage plugin supervisor.

  Owns long-running StockSage plugin children. v0.22 adds
  `StockSage.TraderBridge` as the supervised Port wrapper for the explicit
  Python comparison bridge. v0.25 adds `StockSage.Agents.Supervisor` for the
  native specialist-agent graph. Children crash and restart inside this
  supervisor; they do not propagate to Allbert core supervision.
  """

  use Supervisor

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    :ok =
      AllbertAssist.Objectives.Proposer.register_app_proposer(:stocksage, StockSage.Proposer)

    children = [
      {StockSage.Agents.Supervisor, []},
      {StockSage.TraderBridge, []}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
