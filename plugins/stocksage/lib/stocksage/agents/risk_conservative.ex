defmodule StockSage.Agents.RiskConservative do
  @moduledoc "StockSage native conservative risk specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.risk_conservative",
    role: :risk_conservative,
    type: :jido_ai,
    description: "Argues the conservative risk posture for a candidate trade."
end
