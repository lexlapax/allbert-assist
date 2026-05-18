defmodule StockSage.Agents.CommitteeContextTest do
  use ExUnit.Case, async: true

  alias StockSage.Agents.CommitteeContext

  test "builds an ordered advisory ledger without deciding the final rating" do
    summary =
      CommitteeContext.summary(%{
        "stocksage.risk_conservative.round_1" => %{
          final_trade_decision: "Underweight",
          summary: "Valuation and balance-sheet risk dominate.",
          warnings: ["missing catalyst"]
        },
        "stocksage.bull_thesis.round_1" => %{
          final_trade_decision: "Overweight",
          summary: "Operations are improving."
        },
        "stocksage.market_context" => %{
          final_trade_decision: "Hold",
          summary: "Trend is mixed."
        },
        "stocksage.bear_thesis.round_1" => %{
          final_trade_decision: "Underweight",
          summary: "Weak trend and valuation risk."
        },
        "stocksage.risk_neutral.round_1" => %{
          final_trade_decision: "Hold",
          summary: "Evidence remains unresolved."
        }
      })

    assert summary.rating_counts == %{"Hold" => 2, "Overweight" => 1, "Underweight" => 2}
    assert summary.directional_balance == %{constructive: 1, neutral: 2, cautious: 2}

    assert Enum.map(summary.ordered_stances, & &1.agent_id) == [
             "stocksage.market_context",
             "stocksage.bull_thesis.round_1",
             "stocksage.bear_thesis.round_1",
             "stocksage.risk_conservative.round_1",
             "stocksage.risk_neutral.round_1"
           ]

    assert Enum.map(summary.risk_committee, & &1.agent_id) == [
             "stocksage.risk_conservative.round_1",
             "stocksage.risk_neutral.round_1"
           ]

    assert Enum.any?(summary.cautious_reports, &(&1.agent_id == "stocksage.bear_thesis.round_1"))

    assert summary.decision_guidance =~
             "Use this ledger only as advisory structure"
  end

  test "orders prior reports for stable prompt context and tolerates nil warnings" do
    reports = %{
      "stocksage.risk_neutral.round_2" => %{summary: "Neutral second round", warnings: nil},
      "stocksage.trader_plan" => %{summary: "Trader plan", warnings: "legacy warning"},
      "stocksage.market_context" => %{summary: "Market context", warnings: []},
      "stocksage.research_manager" => %{summary: "Research decision"},
      "stocksage.bear_thesis.round_1" => %{summary: "Bear first round"},
      "stocksage.risk_conservative.round_1" => %{summary: "Conservative first round"}
    }

    assert Enum.map(CommitteeContext.ordered_reports(reports), fn {agent_id, _report} ->
             agent_id
           end) == [
             "stocksage.market_context",
             "stocksage.bear_thesis.round_1",
             "stocksage.research_manager",
             "stocksage.trader_plan",
             "stocksage.risk_conservative.round_1",
             "stocksage.risk_neutral.round_2"
           ]

    summary = CommitteeContext.summary(reports)
    trader = Enum.find(summary.ordered_stances, &(&1.agent_id == "stocksage.trader_plan"))

    assert trader.warnings == ["\"legacy warning\""]
  end
end
