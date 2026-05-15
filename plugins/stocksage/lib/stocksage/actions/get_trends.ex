defmodule StockSage.Actions.GetTrends do
  @moduledoc false

  use Jido.Action,
    name: "get_trends",
    description: "Summarize local StockSage outcome trends without fetching market data.",
    category: "stocksage",
    tags: ["stocksage", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      symbol: [type: :string, required: false],
      limit: [type: :integer, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias StockSage.{Actions, Analyses}

  def capability, do: Actions.capability(:read_only)

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:read_only, context)
    user_id = Actions.user_id(params, context)

    if Actions.allowed?(permission_decision) do
      trends =
        Analyses.summarize_trends(user_id,
          symbol: Actions.field(params, :symbol),
          limit: Actions.positive_limit(Actions.field(params, :limit), 50)
        )

      {:ok,
       %{
         message: "StockSage trends include #{trends.returned} local outcomes.",
         status: :completed,
         trends:
           Map.update!(
             trends,
             :outcomes,
             &Enum.map(&1, fn outcome -> outcome_summary(outcome) end)
           ),
         actions: [
           Actions.action("get_trends", :completed, :read_only, permission_decision, %{
             returned: trends.returned
           })
         ]
       }}
    else
      status = Actions.status_from_decision(permission_decision)

      {:ok,
       %{
         message: "StockSage trends are not available to this request.",
         status: status,
         error: :permission_denied,
         actions: [Actions.action("get_trends", status, :read_only, permission_decision)]
       }}
    end
  end

  defp outcome_summary(outcome) do
    %{
      id: outcome.id,
      symbol: outcome.symbol,
      label: outcome.label,
      horizon_days: outcome.horizon_days,
      observed_on: outcome.observed_on,
      return_pct: outcome.return_pct
    }
  end
end
