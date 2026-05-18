defmodule StockSage.Agents.NativeCoordinatorTest do
  use StockSage.DataCase, async: false

  import ExUnit.CaptureLog

  alias AllbertAssist.Objectives
  alias AllbertAssist.Settings
  alias StockSage.Agents.NativeCoordinator

  @request %{
    ticker: "AAPL",
    analysis_date: "2026-05-15",
    user_id: "alice",
    evidence_mode: "fixture",
    fixture: true,
    parent: %{permission: :stocksage_analyze, approved?: true}
  }

  setup do
    put_setting!("stocksage.native_max_debate_rounds", 1)
    put_setting!("stocksage.native_max_risk_rounds", 1)
    :ok
  end

  test "runs the single-round ten-agent graph with fixture evidence" do
    assert {:ok, report} = NativeCoordinator.analyze(@request)

    assert report.engine == "native"
    assert report.ticker == "AAPL"
    assert report.status == :ok
    assert report.final_trade_decision in ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
    assert map_size(report.agent_reports) == 10
    assert report.agent_reports["stocksage.market_context"].evidence_used != []

    assert get_in(hd(report.agent_reports["stocksage.market_context"].evidence_used), [
             :evidence,
             :payload,
             "ticker"
           ]) == "AAPL"

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

  test "configured debate and risk rounds create one objective step per agent turn" do
    put_setting!("stocksage.native_max_debate_rounds", 2)
    put_setting!("stocksage.native_max_risk_rounds", 3)

    {:ok, objective} =
      Objectives.create_objective(%{
        user_id: "alice",
        title: "Analyze AAPL",
        objective: "Run a native StockSage analysis for AAPL.",
        status: "open",
        active_app: "stocksage"
      })

    assert {:ok, report} =
             NativeCoordinator.analyze(Map.put(@request, :objective_id, objective.id))

    assert report.status == :ok
    assert Map.has_key?(report.agent_reports, "stocksage.bull_thesis.round_1")
    assert Map.has_key?(report.agent_reports, "stocksage.bear_thesis.round_2")
    assert Map.has_key?(report.agent_reports, "stocksage.risk_aggressive.round_3")
    assert Map.has_key?(report.agent_reports, "stocksage.risk_conservative.round_3")
    assert Map.has_key?(report.agent_reports, "stocksage.risk_neutral.round_3")
    assert length(report.debate_rounds) == 3

    steps = Objectives.list_steps(objective.id)
    assert length(steps) == 18
    assert Enum.count(steps, &(&1.delegate_agent_id == "stocksage.bull_thesis")) == 2
    assert Enum.count(steps, &(&1.delegate_agent_id == "stocksage.bear_thesis")) == 2
    assert Enum.count(steps, &(&1.delegate_agent_id == "stocksage.risk_aggressive")) == 3
    assert Enum.count(steps, &(&1.delegate_agent_id == "stocksage.risk_conservative")) == 3
    assert Enum.count(steps, &(&1.delegate_agent_id == "stocksage.risk_neutral")) == 3
    assert Enum.all?(steps, &(&1.status == "completed"))
  end

  test "request round caps override settings and remain bounded" do
    put_setting!("stocksage.native_max_debate_rounds", 5)
    put_setting!("stocksage.native_max_risk_rounds", 3)

    assert {:ok, report} =
             NativeCoordinator.analyze(
               @request
               |> Map.put(:max_debate_rounds, 1)
               |> Map.put(:max_risk_rounds, 1)
             )

    assert map_size(report.agent_reports) == 10
    assert Map.has_key?(report.agent_reports, "stocksage.bull_thesis.round_1")
    refute Map.has_key?(report.agent_reports, "stocksage.bull_thesis.round_2")
    refute Map.has_key?(report.agent_reports, "stocksage.risk_aggressive.round_2")
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end
end
