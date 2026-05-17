defmodule StockSage.Agents.NewsSentiment do
  @moduledoc "StockSage native news and sentiment specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.news_sentiment",
    role: :news_sentiment,
    type: :jido_ai,
    description: "Summarizes news and sentiment evidence for a ticker."
end
