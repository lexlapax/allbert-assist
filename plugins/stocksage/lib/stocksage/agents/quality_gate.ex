defmodule StockSage.Agents.QualityGate do
  @moduledoc "Deterministic StockSage native quality gate specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.quality_gate",
    role: :quality_gate,
    type: :jido,
    description: "Validates the bounded StockSage native report shape."
end
