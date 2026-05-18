defmodule StockSage.Agents.TraderPlan do
  @moduledoc "StockSage native trader-plan specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.trader_plan",
    role: :trader_plan,
    type: :jido_ai,
    description: "Translates the preliminary research decision into a bounded advisory plan."
end
