defmodule StockSage.Actions.RunAnalysisNativeTest do
  use StockSage.DataCase, async: false

  defmodule FakeLLMProvider do
    def generate_report(spec, request, _evidence, prior_reports, model_profile) do
      if pid = Application.get_env(:allbert_assist, :stocksage_llm_test_pid) do
        send(pid, {:stocksage_llm_called, spec.id, model_profile})
      end

      ticker = Map.get(request, :ticker, "UNKNOWN")

      extra =
        if spec.role == :decision_synthesizer do
          %{
            final_trade_decision: "Overweight",
            rating: "Overweight",
            recommendation: "Overweight",
            investment_plan: "Stage exposure and review evidence drift.",
            trader_investment_plan: "No autonomous order placement.",
            market_report: report_text(prior_reports, "stocksage.market_context"),
            sentiment_report: report_text(prior_reports, "stocksage.news_sentiment"),
            news_report: report_text(prior_reports, "stocksage.news_sentiment"),
            fundamentals_report: report_text(prior_reports, "stocksage.fundamentals")
          }
        else
          %{}
        end

      {:ok,
       %{
         summary: "#{spec.id} LLM report for #{ticker}.",
         report: "#{spec.id} used Jido.AI fake provider for #{ticker}.",
         confidence: 0.77,
         warnings: [],
         data_requests: [],
         generation_mode: "jido_ai_llm",
         extra: extra
       }}
    end

    defp report_text(reports, key) do
      reports
      |> Map.get(key, %{})
      |> Map.get(:report, "")
    end
  end

  alias AllbertAssist.Actions.Runner
  alias AllbertAssist.Objectives
  alias AllbertAssist.Settings
  alias StockSage.Analyses

  setup do
    put_setting!("stocksage.native_engine_enabled", true)
    put_setting!("stocksage.native_llm_enabled", false)
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

    [action] = response.actions
    native_trace = get_in(action, [:stocksage, :native_trace])
    assert is_map(native_trace)
    assert length(native_trace["agent_reports"]) == 12
    assert native_trace["generation_modes"] == ["deterministic_advisory"]

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
    assert length(steps) == 12
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

  test "approved native run can use Jido.AI provider-backed specialist generation" do
    original = Application.get_env(:allbert_assist, StockSage.Agents.LLM, [])

    Application.put_env(:allbert_assist, StockSage.Agents.LLM,
      provider: FakeLLMProvider,
      enabled?: true
    )

    Application.put_env(:allbert_assist, :stocksage_llm_test_pid, self())

    on_exit(fn ->
      Application.put_env(:allbert_assist, StockSage.Agents.LLM, original)
      Application.delete_env(:allbert_assist, :stocksage_llm_test_pid)
    end)

    put_setting!("stocksage.native_llm_enabled", true)

    params = %{
      ticker: "AAPL",
      analysis_date: "2026-05-15",
      user_id: "alice",
      engine: "native",
      evidence_mode: "fixture"
    }

    context = %{
      confirmation: %{approved?: true, id: "native-llm-confirmation"},
      trace_id: "trace-native-llm-analysis"
    }

    assert {:ok, response} = Runner.run("run_analysis", params, context)

    assert response.status == :completed

    {:ok, analysis} = Analyses.get_analysis_with_details("alice", response.analysis_id)
    assert analysis.recommendation == "Overweight"

    [action] = response.actions
    native_trace = get_in(action, [:stocksage, :native_trace])

    assert "jido_ai_llm" in native_trace["generation_modes"]

    assert Enum.any?(
             native_trace["agent_reports"],
             &(&1["agent_id"] == "stocksage.decision_synthesizer")
           )

    called =
      for _ <- 1..11 do
        assert_receive {:stocksage_llm_called, agent_id, _model_profile}, 1_000
        agent_id
      end

    assert "stocksage.research_manager" in called
    assert "stocksage.trader_plan" in called
    assert "stocksage.decision_synthesizer" in called
    refute "stocksage.quality_gate" in called
  end

  defp put_setting!(key, value) do
    case Settings.put(key, value, %{actor: "test"}) do
      {:ok, _resolved} -> :ok
      {:error, reason} -> flunk("Settings.put #{inspect(key)} failed: #{inspect(reason)}")
    end
  end
end
