defmodule StockSage.Domain.AnalysesTest do
  use StockSage.DataCase

  alias StockSage.Analyses
  alias StockSage.Domain.Analysis

  describe "analysis changesets" do
    test "require user, symbol, status, and source" do
      changeset = Analysis.changeset(%Analysis{}, %{})

      assert %{id: [_], user_id: [_], symbol: [_]} = errors_on(changeset)
    end

    test "validate enum fields and normalize symbols" do
      assert {:error, changeset} =
               Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: " aapl ",
                 status: "unknown",
                 source: "manual"
               })

      assert %{status: [_]} = errors_on(changeset)

      assert {:ok, analysis} =
               Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: " aapl ",
                 status: "completed",
                 source: "manual"
               })

      assert analysis.symbol == "AAPL"
    end
  end

  describe "analysis context" do
    test "lists and gets analyses by user scope" do
      assert {:ok, alice} =
               Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: "msft",
                 source: "manual",
                 status: "completed"
               })

      assert {:ok, _bob} =
               Analyses.create_analysis(%{
                 user_id: "bob",
                 symbol: "MSFT",
                 source: "manual",
                 status: "completed"
               })

      assert [analysis] = Analyses.list_analyses("alice", symbol: "msft")
      assert analysis.id == alice.id
      assert {:ok, ^alice} = Analyses.get_analysis("alice", alice.id)
      assert {:error, :not_found} = Analyses.get_analysis("bob", alice.id)
    end

    test "paginates results with a bounded limit" do
      for symbol <- ~w[AAPL MSFT NVDA] do
        assert {:ok, _analysis} =
                 Analyses.create_analysis(%{
                   user_id: "alice",
                   symbol: symbol,
                   source: "manual",
                   status: "completed"
                 })
      end

      assert [_one] = Analyses.list_analyses("alice", limit: 1)
      assert [_one, _two] = Analyses.list_analyses("alice", limit: 2)
    end

    test "upserts analyses idempotently by legacy provenance" do
      attrs = %{
        user_id: "alice",
        symbol: "aapl",
        source: "legacy_sqlite",
        status: "imported",
        legacy_source: "stocksage.db",
        legacy_id: "analysis-1",
        summary: "first"
      }

      assert {:ok, first} = Analyses.upsert_analysis(attrs)
      assert {:ok, second} = Analyses.upsert_analysis(%{attrs | summary: "updated"})

      assert first.id == second.id
      assert second.summary == "updated"
      assert [_one] = Analyses.list_analyses("alice")
    end

    test "details and outcomes are scoped by user through read paths" do
      assert {:ok, analysis} =
               Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: "aapl",
                 source: "manual",
                 status: "completed"
               })

      assert {:ok, _detail} =
               Analyses.create_detail(%{
                 user_id: "alice",
                 analysis_id: analysis.id,
                 section: "technical",
                 content: "trend"
               })

      assert {:ok, _outcome} =
               Analyses.create_outcome(%{
                 user_id: "alice",
                 analysis_id: analysis.id,
                 symbol: "aapl",
                 label: "win"
               })

      assert [detail] = Analyses.list_details_for_analysis("alice", analysis.id)
      assert detail.section == "technical"
      assert [] = Analyses.list_details_for_analysis("bob", analysis.id)

      assert %{counts: %{"win" => 1}, returned: 1} = Analyses.summarize_trends("alice")
      assert %{counts: %{}, returned: 0} = Analyses.summarize_trends("bob")
    end

    test "summarize_trends includes accuracy, rating calibration, and leaderboard" do
      assert {:ok, buy_aapl} =
               Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: "aapl",
                 source: "manual",
                 status: "completed",
                 recommendation: "Buy"
               })

      assert {:ok, sell_msft} =
               Analyses.create_analysis(%{
                 user_id: "alice",
                 symbol: "msft",
                 source: "manual",
                 status: "completed",
                 recommendation: "Sell"
               })

      assert {:ok, _aapl_win} =
               Analyses.create_outcome(%{
                 user_id: "alice",
                 analysis_id: buy_aapl.id,
                 symbol: "aapl",
                 label: "win",
                 return_pct: Decimal.new("8.0")
               })

      assert {:ok, _aapl_loss} =
               Analyses.create_outcome(%{
                 user_id: "alice",
                 analysis_id: buy_aapl.id,
                 symbol: "aapl",
                 label: "loss",
                 return_pct: Decimal.new("-4.0")
               })

      assert {:ok, _msft_win} =
               Analyses.create_outcome(%{
                 user_id: "alice",
                 analysis_id: sell_msft.id,
                 symbol: "msft",
                 label: "win",
                 return_pct: Decimal.new("-6.0")
               })

      assert {:ok, _pending} =
               Analyses.create_outcome(%{
                 user_id: "alice",
                 analysis_id: sell_msft.id,
                 symbol: "msft",
                 label: "pending"
               })

      trends = Analyses.summarize_trends("alice")

      assert trends.returned == 4
      assert trends.counts == %{"loss" => 1, "pending" => 1, "win" => 2}
      assert trends.accuracy.resolved == 3
      assert trends.accuracy.wins == 2
      assert trends.accuracy.losses == 1
      assert trends.accuracy.win_rate == 66.67
      assert Decimal.equal?(trends.accuracy.avg_return_pct, Decimal.new("-0.6667"))

      assert [
               %{rating: "Sell", resolved: 1, wins: 1, win_rate: 100.0},
               %{rating: "Buy", resolved: 2, wins: 1, losses: 1, win_rate: 50.0}
             ] = trends.rating_calibration

      assert [
               %{symbol: "MSFT", resolved: 1, wins: 1, win_rate: 100.0},
               %{symbol: "AAPL", resolved: 2, wins: 1, losses: 1, win_rate: 50.0}
             ] = trends.leaderboard
    end
  end
end
