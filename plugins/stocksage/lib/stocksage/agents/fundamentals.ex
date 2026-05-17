defmodule StockSage.Agents.Fundamentals do
  @moduledoc "StockSage native fundamentals specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.fundamentals",
    role: :fundamentals,
    type: :jido_ai,
    description: "Summarizes company fundamentals and financial context."
end
