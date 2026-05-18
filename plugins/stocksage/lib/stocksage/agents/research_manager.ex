defmodule StockSage.Agents.ResearchManager do
  @moduledoc "StockSage native research-manager specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.research_manager",
    role: :research_manager,
    type: :jido_ai,
    description: "Arbitrates bull/bear debate into a preliminary research decision."
end
