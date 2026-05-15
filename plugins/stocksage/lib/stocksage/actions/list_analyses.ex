defmodule StockSage.Actions.ListAnalyses do
  @moduledoc false

  use Jido.Action,
    name: "list_analyses",
    description: "List bounded local StockSage analyses for the current user.",
    category: "stocksage",
    tags: ["stocksage", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      symbol: [type: :string, required: false],
      limit: [type: :integer, required: false],
      offset: [type: :integer, required: false]
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

    with {:ok, user_id} <- Actions.user_id(params, context) do
      maybe_list(user_id, params, permission_decision)
    else
      {:error, :missing_user_id} ->
        Actions.missing_user("list_analyses", :read_only, permission_decision)
    end
  end

  defp maybe_list(user_id, params, permission_decision) do
    if Actions.allowed?(permission_decision) do
      opts = [
        symbol: Actions.field(params, :symbol),
        limit: Actions.positive_limit(Actions.field(params, :limit), 50),
        offset: Actions.offset(Actions.field(params, :offset))
      ]

      analyses = Analyses.list_analyses(user_id, opts)
      summaries = Enum.map(analyses, &summary/1)

      {:ok,
       %{
         message: message(user_id, summaries),
         status: :completed,
         user_id: user_id,
         analyses: summaries,
         actions: [
           Actions.action("list_analyses", :completed, :read_only, permission_decision, %{
             returned: length(summaries)
           })
         ]
       }}
    else
      denied("list_analyses", permission_decision)
    end
  end

  defp summary(analysis) do
    %{
      id: analysis.id,
      symbol: analysis.symbol,
      status: analysis.status,
      analysis_date: analysis.analysis_date,
      recommendation: analysis.recommendation,
      score: analysis.score,
      source: analysis.source,
      inserted_at: analysis.inserted_at,
      updated_at: analysis.updated_at
    }
  end

  defp message(_user_id, []), do: "No StockSage analyses found."

  defp message(user_id, analyses) do
    "Found #{length(analyses)} StockSage analyses for #{user_id}."
  end

  defp denied(name, permission_decision) do
    status = Actions.status_from_decision(permission_decision)

    {:ok,
     %{
       message: "StockSage analyses are not available to this request.",
       status: status,
       error: :permission_denied,
       actions: [
         Actions.action(name, status, :read_only, permission_decision, %{
           error: :permission_denied
         })
       ]
     }}
  end
end
