defmodule StockSage.Actions.Evidence.FetchSentiment do
  @moduledoc false

  use AllbertAssist.Action,
  alias StockSage.Actions.Evidence
    registry_order: 279,
    permission: :stocksage_evidence_fetch,
    exposure: :internal,
    execution_mode: :req_http,
    skill_backed?: false,
    confirmation: :required,
    app_id: :stocksage,
    plugin_id: "stocksage",
    name: "stocksage_fetch_sentiment",
    description: "Fetch bounded sentiment evidence for StockSage native agents.",
    category: "stocksage",
    tags: ["stocksage", "evidence", "sentiment"],
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

  def capability, do: Evidence.capability()

  @impl true
  def run(params, context),
    do: Evidence.run(:sentiment, name(), params, context)
end
