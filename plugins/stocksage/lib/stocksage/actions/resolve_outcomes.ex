defmodule StockSage.Actions.ResolveOutcomes do
  @moduledoc false

  use Jido.Action,
    name: "resolve_outcomes",
    description: "Resolve due StockSage outcomes from already-recorded prices.",
    category: "stocksage",
    tags: ["stocksage", "outcomes", "write"],
    schema: [
      user_id: [type: :string, required: false],
      as_of: [type: :string, required: false],
      prices: [type: :map, required: false],
      limit: [type: :integer, required: false],
      force: [type: :boolean, required: false],
      neutral_return_threshold_pct: [type: :string, required: false]
    ],
    output_schema: [
      message: [type: :string, required: true],
      status: [type: :atom, required: true],
      actions: [type: {:list, :map}, required: true]
    ]

  alias StockSage.{Actions, Outcomes}

  def capability, do: Actions.capability(:stocksage_write, %{exposure: :internal})

  @impl true
  def run(params, context) do
    permission_decision = Actions.authorize(:stocksage_write, context)

    with {:ok, user_id} <- Actions.user_id(params, context) do
      if Actions.allowed?(permission_decision) do
        resolution =
          Outcomes.resolve_due(user_id,
            as_of: Actions.field(params, :as_of),
            prices: Actions.field(params, :prices, %{}),
            limit: Actions.positive_limit(Actions.field(params, :limit), 50),
            force: Actions.field(params, :force, false),
            neutral_return_threshold_pct: Actions.field(params, :neutral_return_threshold_pct)
          )

        {:ok,
         %{
           message:
             "Resolved #{resolution.resolved} of #{resolution.attempted} StockSage outcomes.",
           status: :completed,
           outcome_resolution: resolution,
           actions: [
             Actions.action(
               "resolve_outcomes",
               :completed,
               :stocksage_write,
               permission_decision,
               %{
                 attempted: resolution.attempted,
                 resolved: resolution.resolved,
                 pending: resolution.pending,
                 skipped: resolution.skipped
               }
             )
           ]
         }}
      else
        status = Actions.status_from_decision(permission_decision)

        {:ok,
         %{
           message: "StockSage outcome resolution is not available to this request.",
           status: status,
           error: :permission_denied,
           actions: [
             Actions.action("resolve_outcomes", status, :stocksage_write, permission_decision, %{
               error: :permission_denied
             })
           ]
         }}
      end
    else
      {:error, :missing_user_id} ->
        Actions.missing_user("resolve_outcomes", :stocksage_write, permission_decision)
    end
  end
end
