defmodule StockSage.Actions.Evidence.FetchFinancials do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :stocksage_evidence_fetch,
    exposure: :internal,
    execution_mode: :req_http,
    skill_backed?: false,
    confirmation: :required,
    app_id: :stocksage,
    plugin_id: "stocksage",
    name: "stocksage_fetch_financials",
    description: "Fetch bounded financial statement evidence for StockSage native agents.",
    category: "stocksage",
    tags: ["stocksage", "evidence", "financials"],
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
    do: StockSage.Actions.Evidence.run(:financials, name(), params, context)
end
