defmodule StockSage.Agents.RiskNeutral do
  @moduledoc "StockSage native neutral risk specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.risk_neutral",
    role: :risk_neutral,
    type: :jido_ai,
    description: "Argues the neutral risk posture for a candidate trade."
end
