defmodule StockSage.Agents.DecisionSynthesizerTest do
  use StockSage.DataCase, async: false

  alias StockSage.Agents.Commands.Execute

  defmodule FakeLLMProvider do
    def generate_report(spec, request, evidence, prior_reports, model_profile) do
      if pid = Application.get_env(:allbert_assist, :stocksage_decision_synthesizer_test_pid) do
        send(pid, {
          :decision_synthesizer_called,
          %{
            role: spec.role,
            model_profile: model_profile,
            evidence: evidence,
            request: request,
            prior_keys: prior_reports |> Map.keys() |> Enum.sort()
          }
        })
      end

      {:ok,
       %{
         summary: "Underweight final decision synthesized for PLTR.",
         report:
           "The final trader/risk manager accepts the bearish technical and risk committee " <>
             "warnings over the fundamentals-only bull case.",
         confidence: 0.81,
         warnings: ["valuation and catalyst evidence incomplete"],
         data_requests: [],
         generation_mode: "jido_ai_llm",
         extra: %{
           final_trade_decision: "Underweight",
           rating: "Underweight",
           recommendation: "Underweight",
           investment_plan: "Do not add exposure until trend and valuation evidence improve.",
           trader_investment_plan: "No autonomous order placement; operator review only.",
           market_report: report_text(prior_reports, "stocksage.market_context"),
           sentiment_report: report_text(prior_reports, "stocksage.news_sentiment"),
           news_report: report_text(prior_reports, "stocksage.news_sentiment"),
           fundamentals_report: report_text(prior_reports, "stocksage.fundamentals")
         }
       }}
    end

    defp report_text(reports, key) do
      reports
      |> Map.get(key, %{})
      |> Map.get(:report, "")
    end
  end

  setup do
    original = Application.get_env(:allbert_assist, StockSage.Agents.LLM, [])

    Application.put_env(:allbert_assist, StockSage.Agents.LLM,
      provider: FakeLLMProvider,
      enabled?: true
    )

    Application.put_env(:allbert_assist, :stocksage_decision_synthesizer_test_pid, self())

    on_exit(fn ->
      Application.put_env(:allbert_assist, StockSage.Agents.LLM, original)
      Application.delete_env(:allbert_assist, :stocksage_decision_synthesizer_test_pid)
    end)

    :ok
  end

  test "uses the LLM path with all prior debate rounds and returns final decision fields" do
    prior_reports = %{
      "stocksage.market_context" => %{
        summary: "Technicals are weak.",
        report: "Price is below major moving averages with negative MACD."
      },
      "stocksage.news_sentiment" => %{
        summary: "Sentiment is cautious.",
        report: "News and social evidence are mixed and valuation-focused."
      },
      "stocksage.fundamentals" => %{
        summary: "Fundamentals are strong.",
        report: "Revenue, earnings, and cash flow improved."
      },
      "stocksage.bull_thesis.round_1" => %{
        summary: "Bull thesis sees fundamental upside.",
        report: "Strong fundamentals justify a constructive stance.",
        final_trade_decision: "Overweight"
      },
      "stocksage.bear_thesis.round_1" => %{
        summary: "Bear thesis names technical and valuation risk.",
        report: "Weak technicals and missing valuation context dominate.",
        final_trade_decision: "Underweight"
      },
      "stocksage.bull_thesis.round_2" => %{
        summary: "Bull thesis narrows to staged upside.",
        report: "Upside requires evidence confirmation.",
        final_trade_decision: "Hold"
      },
      "stocksage.bear_thesis.round_2" => %{
        summary: "Bear thesis remains underweight.",
        report: "No catalyst offsets the technical weakness.",
        final_trade_decision: "Underweight"
      }
    }

    request = %{
      ticker: "PLTR",
      analysis_date: "2026-05-15",
      user_id: "alice",
      fixture: true,
      evidence_mode: "fixture",
      prior_reports: prior_reports,
      round_index: 1,
      stage: :synthesis
    }

    report = Execute.report_for("stocksage.decision_synthesizer", request)

    assert_receive {:decision_synthesizer_called, call}, 1_000
    assert call.role == :decision_synthesizer
    assert call.model_profile == "slow"
    assert call.evidence == []
    assert call.request.stage == :synthesis
    assert "stocksage.bull_thesis.round_2" in call.prior_keys
    assert "stocksage.bear_thesis.round_2" in call.prior_keys

    assert report.agent_id == "stocksage.decision_synthesizer"
    assert report.generation_mode == "jido_ai_llm"
    assert report.final_trade_decision == "Underweight"
    assert report.investment_plan =~ "Do not add exposure"
    assert report.trader_investment_plan =~ "No autonomous order placement"
    assert report.market_report =~ "negative MACD"
    assert report.fundamentals_report =~ "cash flow improved"
    assert report.evidence_used == []
  end
end
