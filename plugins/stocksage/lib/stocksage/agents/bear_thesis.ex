defmodule StockSage.Agents.BearThesis do
  @moduledoc "StockSage native bearish thesis specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.bear_thesis",
    role: :bear_thesis,
    type: :jido_ai,
    description: "Produces the strongest bounded bearish thesis."
end
