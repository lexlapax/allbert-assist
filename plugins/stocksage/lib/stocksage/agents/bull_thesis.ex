defmodule StockSage.Agents.BullThesis do
  @moduledoc "StockSage native bullish thesis specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.bull_thesis",
    role: :bull_thesis,
    type: :jido_ai,
    description: "Produces the strongest bounded bullish thesis."
end
