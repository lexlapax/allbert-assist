defmodule StockSage.Actions.ShowAnalysis do
  @moduledoc false

  use AllbertAssist.Action,
    permission: :read_only,
    exposure: :agent,
    execution_mode: :local_domain,
    skill_backed?: true,
    confirmation: :not_required,
    app_id: :stocksage,
    plugin_id: "stocksage",
    name: "show_analysis",
    description: "Show one bounded local StockSage analysis for the current user.",
    category: "stocksage",
    tags: ["stocksage", "read_only"],
    schema: [
      user_id: [type: :string, required: false],
      analysis_id: [type: :string, required: true]
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
      analysis_id = Actions.field(params, :analysis_id) || Actions.field(params, :id)

      if Actions.allowed?(permission_decision) do
        case Analyses.get_analysis_with_details(user_id, analysis_id) do
          {:ok, analysis} ->
            {:ok, completed(user_id, analysis, permission_decision)}

          {:error, :not_found} ->
            {:ok, not_found(analysis_id, permission_decision)}
        end
      else
        denied(permission_decision)
      end
    else
      {:error, :missing_user_id} ->
        Actions.missing_user("show_analysis", :read_only, permission_decision)
    end
  end

  defp completed(user_id, analysis, permission_decision) do
    details = Enum.map(analysis.details, &detail_summary/1)
    outcomes = Enum.map(analysis.outcomes, &outcome_summary/1)

    %{
      message: "StockSage analysis #{analysis.id} for #{user_id}.",
      status: :completed,
      user_id: user_id,
      analysis: %{
        id: analysis.id,
        symbol: analysis.symbol,
        status: analysis.status,
        analysis_date: analysis.analysis_date,
        recommendation: analysis.recommendation,
        score: analysis.score,
        summary: analysis.summary,
        source: analysis.source,
        details: details,
        outcomes: outcomes
      },
      actions: [
        Actions.action("show_analysis", :completed, :read_only, permission_decision, %{
          detail_count: length(details),
          outcome_count: length(outcomes)
        })
      ]
    }
  end

  defp not_found(analysis_id, permission_decision) do
    %{
      message: "StockSage analysis not found: #{analysis_id}",
      status: :not_found,
      error: :not_found,
      actions: [
        Actions.action("show_analysis", :not_found, :read_only, permission_decision, %{
          error: :not_found
        })
      ]
    }
  end

  defp denied(permission_decision) do
    status = Actions.status_from_decision(permission_decision)

    {:ok,
     %{
       message: "StockSage analysis detail is not available to this request.",
       status: status,
       error: :permission_denied,
       actions: [
         Actions.action("show_analysis", status, :read_only, permission_decision, %{
           error: :permission_denied
         })
       ]
     }}
  end

  defp detail_summary(detail) do
    # Only expose the vetted operator-facing payload fields. Imported legacy
    # rows can carry arbitrary payload_json, so never return the raw map here.
    %{
      id: detail.id,
      section: detail.section,
      agent: detail.agent,
      content: detail.content,
      payload: detail_payload_summary(detail.payload)
    }
  end

  defp detail_payload_summary(payload) when is_map(payload) do
    %{}
    |> maybe_payload(payload, "engine")
    |> maybe_payload(payload, "truncated")
    |> maybe_payload(payload, "stub")
  end

  defp detail_payload_summary(_payload), do: %{}

  defp maybe_payload(summary, payload, key) do
    case Map.fetch(payload, key) do
      {:ok, value} ->
        Map.put(summary, key, value)

      :error ->
        case Map.fetch(payload, String.to_atom(key)) do
          {:ok, value} -> Map.put(summary, key, value)
          :error -> summary
        end
    end
  end

  defp outcome_summary(outcome) do
    %{
      id: outcome.id,
      symbol: outcome.symbol,
      horizon_days: outcome.horizon_days,
      observed_on: outcome.observed_on,
      label: outcome.label,
      return_pct: outcome.return_pct
    }
  end
end
