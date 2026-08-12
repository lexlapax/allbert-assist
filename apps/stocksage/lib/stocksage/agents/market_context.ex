defmodule StockSage.Agents.MarketContext do
  @moduledoc "StockSage native market and technical context specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.market_context",
    role: :market_context,
    type: :jido_ai,
    description: "Builds bounded market and technical context for a ticker."
end
