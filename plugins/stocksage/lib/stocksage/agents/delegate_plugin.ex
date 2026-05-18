defmodule StockSage.Agents.DelegatePlugin do
  @moduledoc false

  @dialyzer {:nowarn_function, __plugin_metadata__: 0}
  @dialyzer {:nowarn_function, actions: 0}
  @dialyzer {:nowarn_function, handle_signal: 2}
  @dialyzer {:nowarn_function, mount: 2}
  @dialyzer {:nowarn_function, on_checkpoint: 2}
  @dialyzer {:nowarn_function, on_restore: 2}
  @dialyzer {:nowarn_function, state_key: 0}

  use Jido.Plugin,
    name: "stocksage_delegate",
    state_key: :stocksage_delegate,
    actions: [StockSage.Agents.Commands.Execute],
    signal_routes: [
      {"allbert.objectives.delegate.execute", StockSage.Agents.Commands.Execute}
    ]
end
