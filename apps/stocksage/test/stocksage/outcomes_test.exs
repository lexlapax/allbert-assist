defmodule StockSage.OutcomesTest do
  use StockSage.DataCase

  alias StockSage.{Analyses, Outcomes}

  test "resolve_due labels due bullish outcomes from supplied observed prices" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               analysis_date: ~D[2026-05-01],
               status: "completed",
               source: "manual",
               recommendation: "Buy",
               objective_id: "obj_outcome_1",
               step_id: "step_outcome_1"
             })

    assert {:ok, outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "aapl",
               horizon_days: 5,
               start_price: Decimal.new("100.00"),
               label: "pending"
             })

    resolution =
      Outcomes.resolve_due("alice",
        as_of: ~D[2026-05-10],
        prices: %{"AAPL" => "112.50"},
        neutral_return_threshold_pct: "0.5"
      )

    assert resolution.attempted == 1
    assert resolution.resolved == 1

    assert [%{id: id, status: :resolved, label: "win", return_pct: return_pct}] =
             resolution.outcomes

    assert id == outcome.id
    assert Decimal.equal?(return_pct, Decimal.new("12.5000"))

    assert [updated] = Analyses.list_outcomes_for_analysis("alice", analysis.id)
    assert updated.label == "win"
    assert Decimal.equal?(updated.end_price, Decimal.new("112.50"))
    assert Decimal.equal?(updated.return_pct, Decimal.new("12.5000"))
    assert updated.metadata["resolution"]["objective_id"] == "obj_outcome_1"
    assert updated.metadata["resolution"]["source"] == "stocksage_outcome_resolver"

    second_pass =
      Outcomes.resolve_due("alice",
        as_of: ~D[2026-05-10],
        prices: %{"AAPL" => "112.50"}
      )

    assert second_pass.attempted == 0
    assert second_pass.resolved == 0
  end

  test "resolve_due leaves outcomes pending when observed price is missing" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "msft",
               analysis_date: ~D[2026-05-01],
               status: "completed",
               source: "manual",
               recommendation: "Sell"
             })

    assert {:ok, _outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "msft",
               horizon_days: 5,
               start_price: Decimal.new("100.00"),
               label: "pending"
             })

    resolution = Outcomes.resolve_due("alice", as_of: ~D[2026-05-10])

    assert resolution.attempted == 1
    assert resolution.pending == 1
    assert [%{status: :pending, reason: :missing_end_price}] = resolution.outcomes

    assert [updated] = Analyses.list_outcomes_for_analysis("alice", analysis.id)
    assert updated.label == "pending"
    assert updated.metadata["resolution"]["reason"] == "missing_end_price"
  end

  test "resolve_due skips future outcomes without mutating the label" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "nvda",
               analysis_date: ~D[2026-05-01],
               status: "completed",
               source: "manual",
               recommendation: "Buy"
             })

    assert {:ok, outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "nvda",
               horizon_days: 30,
               start_price: Decimal.new("100.00"),
               label: "pending"
             })

    resolution =
      Outcomes.resolve_due("alice",
        as_of: ~D[2026-05-10],
        prices: %{"NVDA" => "125.00"}
      )

    assert resolution.skipped == 1

    assert [%{id: id, status: :skipped, reason: :not_due, label: "pending"}] =
             resolution.outcomes

    assert id == outcome.id
    assert [updated] = Analyses.list_outcomes_for_analysis("alice", analysis.id)
    assert updated.label == "pending"
    assert is_nil(updated.end_price)
  end
end
