defmodule StockSage.Agents.NativeCoordinatorTest do
  use StockSage.DataCase, async: false

  import ExUnit.CaptureLog

  alias StockSage.Agents.NativeCoordinator

  @request %{
    ticker: "AAPL",
    analysis_date: "2026-05-15",
    user_id: "alice",
    evidence_mode: "fixture",
    fixture: true,
    parent: %{permission: :stocksage_analyze, approved?: true}
  }

  test "runs the single-round ten-agent graph with fixture evidence" do
    assert {:ok, report} = NativeCoordinator.analyze(@request)

    assert report.engine == "native"
    assert report.ticker == "AAPL"
    assert report.status == :ok
    assert report.final_trade_decision in ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
    assert map_size(report.agent_reports) == 10
    assert report.agent_reports["stocksage.market_context"].evidence_used != []
    assert report.agent_reports["stocksage.decision_synthesizer"].final_trade_decision
    assert report.agent_reports["stocksage.quality_gate"].quality_status == :passed
  end

  test "emits the native signal vocabulary for a successful single-round analysis" do
    original_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: original_level) end)

    log =
      capture_log([level: :info], fn ->
        assert {:ok, _report} = NativeCoordinator.analyze(@request)
      end)

    for signal <- [
          "allbert.stocksage.native.analysis_started",
          "allbert.stocksage.native.agent.dispatched",
          "allbert.stocksage.native.agent.completed",
          "allbert.stocksage.native.debate_round.completed",
          "allbert.stocksage.native.synthesis.completed",
          "allbert.stocksage.native.quality_gate.passed"
        ] do
      assert log =~ signal
    end
  end

  test "quality gate rejection returns a structured error" do
    assert {:error, {:quality_gate_rejected, failed_clauses}} =
             NativeCoordinator.analyze(Map.put(@request, :force_quality_reject, true))

    assert :missing_synthesis in failed_clauses
  end

  test "single analyst failure records a warning and continues" do
    assert {:ok, report} =
             NativeCoordinator.analyze(
               Map.put(@request, :fail_agent_id, "stocksage.market_context")
             )

    assert report.status == :ok
    refute Map.has_key?(report.agent_reports, "stocksage.market_context")
    assert Enum.any?(report.warnings, &String.contains?(&1, "stocksage.market_context"))
    assert report.agent_reports["stocksage.quality_gate"].quality_status == :passed
  end
end
