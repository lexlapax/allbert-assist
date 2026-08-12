defmodule StockSage.Agents.DecisionSynthesizer do
  @moduledoc "StockSage native final decision synthesis specialist."

  use StockSage.Agents.Specialist,
    agent_id: "stocksage.decision_synthesizer",
    role: :decision_synthesizer,
    type: :jido_ai,
    description: "Synthesizes specialist outputs into a final trade posture."
end
