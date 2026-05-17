defmodule StockSage.Actions.RunAnalysisNativeTest do
  use StockSage.DataCase, async: false

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Settings
  alias StockSage.Analyses

  setup do
    put_setting!("stocksage.native_engine_enabled", true)
    put_setting!("stocksage.native_max_debate_rounds", 1)
    put_setting!("stocksage.native_max_risk_rounds", 1)
    put_setting!("permissions.stocksage_analyze", "needs_confirmation")
    :ok
  end

  test "approved native run persists native analysis, detail, objective, and delegate steps" do
    params = %{
      ticker: "AAPL",
      analysis_date: "2026-05-15",
      user_id: "alice",
      engine: "native",
      evidence_mode: "fixture"
    }

    context = %{
      confirmation: %{approved?: true, id: "native-confirmation"},
      trace_id: "trace-native-analysis"
    }

    assert {:ok, response} = Runner.run("run_analysis", params, context)

    assert response.status == :completed
    assert response.engine == "native"
    assert response.ticker == "AAPL"
    assert is_binary(response.analysis_id)
    assert is_binary(response.objective_id)
    assert response.summary =~ "decision synthesized"

    {:ok, analysis} = Analyses.get_analysis_with_details("alice", response.analysis_id)
    assert analysis.status == "completed"
    assert analysis.source == "native"
    assert analysis.engine == "native"
    assert analysis.recommendation in ["Buy", "Overweight", "Hold", "Underweight", "Sell"]
    assert analysis.objective_id == response.objective_id

    [detail] = analysis.details
    assert detail.agent == "native_coordinator"
    assert detail.content =~ "agent_reports"
    assert get_in(detail.payload, ["native_report", "final_trade_decision"])

    steps = Objectives.list_steps(response.objective_id)
    assert length(steps) == 10
    assert Enum.all?(steps, &(&1.kind == "delegate_agent"))
    assert Enum.all?(steps, &(&1.status == "completed"))
  end

  test "native engine is the default when no engine is passed" do
    assert {:ok, response} =
             Runner.run(
               "run_analysis",
               %{ticker: "MSFT", analysis_date: "2026-05-15", user_id: "alice"},
               %{}
             )

    assert response.status == :needs_confirmation
    assert response.confirmation["params_summary"]["engine"] == "native"
  end

  test "disabled native engine fails before creating a confirmation" do
    put_setting!("stocksage.native_engine_enabled", false)

    assert {:ok, response} =
             Runner.run(
               "run_analysis",
               %{ticker: "NVDA", analysis_date: "2026-05-15", user_id: "alice"},
               %{}
             )

    assert response.status == :error
    assert response.error == :native_engine_disabled
    refute Map.has_key?(response, :confirmation_id)
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end
end
