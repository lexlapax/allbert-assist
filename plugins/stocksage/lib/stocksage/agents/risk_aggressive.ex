defmodule StockSage.Agents.RiskAggressive do
  @moduledoc "StockSage native aggressive risk specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.risk_aggressive",
    role: :risk_aggressive,
    type: :jido_ai,
    description: "Argues the aggressive risk posture for a candidate trade."
end
