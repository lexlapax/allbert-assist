defmodule StockSage.Actions.Evidence.FetchFundamentals do
  @moduledoc false

  use Jido.Action,
    name: "stocksage_fetch_fundamentals",
    description: "Fetch bounded fundamentals evidence for StockSage native agents.",
    category: "stocksage",
    tags: ["stocksage", "evidence", "fundamentals"],
    schema: [
      ticker: [type: :string, required: true],
      analysis_date: [type: :string, required: false],
      evidence_mode: [type: :string, required: false],
      fixture: [type: :boolean, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  def capability, do: StockSage.Actions.Evidence.capability()

  @impl true
  def run(params, context),
    do: StockSage.Actions.Evidence.run(:fundamentals, name(), params, context)
end
