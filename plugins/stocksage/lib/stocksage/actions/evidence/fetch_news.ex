defmodule StockSage.Actions.Evidence.FetchNews do
  @moduledoc false

  use Jido.Action,
    name: "stocksage_fetch_news",
    description: "Fetch bounded news evidence for StockSage native agents.",
    category: "stocksage",
    tags: ["stocksage", "evidence", "news"],
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
  def run(params, context), do: StockSage.Actions.Evidence.run(:news, name(), params, context)
end
