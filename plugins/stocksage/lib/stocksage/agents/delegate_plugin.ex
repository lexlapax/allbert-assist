defmodule StockSage.Agents.DelegatePlugin do
  @moduledoc false

  use Jido.Plugin,
    name: "stocksage_delegate",
    state_key: :stocksage_delegate,
    actions: [StockSage.Agents.Commands.Execute],
    signal_routes: [
      {"allbert.objectives.delegate.execute", StockSage.Agents.Commands.Execute}
    ]
end
