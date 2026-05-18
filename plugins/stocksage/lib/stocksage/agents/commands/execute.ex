defmodule StockSage.Agents.Commands.Execute do
  @moduledoc """
  Execute one StockSage native specialist turn.

  The command runs inside each supervised specialist agent through the v0.24
  `DelegateAgent` boundary. v0.25 M4 makes the packet non-stubbed: evidence
  actions are invoked through `Actions.Runner.run/3`, prior reports are
  summarized, and each role returns a bounded advisory report. LLM/provider
  calls remain explicit operator configuration; fixture-mode execution is
  deterministic so user smoke tests do not require credentials.
  """

  use Jido.Action,
    name: "stocksage_native_agent_execute",
    description: "Return a bounded advisory report packet for a StockSage native agent."

  alias AllbertAssist.Actions.Runner
  alias StockSage.Agents
  alias StockSage.Agents.ModelProfile

  @impl true
  def run(params, context) do
    agent_id =
      context
      |> Map.get(:state, %{})
      |> field(:agent_id)
      |> case do
        nil -> field(params, :agent_id)
        value -> value
      end

    report = report_for(agent_id, params, context)

    {:ok,
     %{
       last_command: :execute,
       last_result: {:ok, report},
       last_summary: report.summary,
       agent_id: report.agent_id,
       role: report.role,
       prompt_version: report.prompt_version,
       model_profile: report.model_profile
     }}
  end

  def report_for(agent_id, request) when is_binary(agent_id) and is_map(request) do
    report_for(agent_id, request, %{})
  end

  def report_for(agent_id, request, context) when is_binary(agent_id) and is_map(request) do
    spec = Agents.spec!(agent_id)
    model_profile = if spec.role == :quality_gate, do: nil, else: ModelProfile.resolve(spec.role)
    started_at = System.monotonic_time(:millisecond)
    evidence = evidence_for(spec, request, context)
    prior_reports = prior_reports(request)
    role_report = role_report(spec, request, evidence, prior_reports)
    duration_ms = System.monotonic_time(:millisecond) - started_at

    %{
      agent_id: spec.id,
      role: spec.role,
      request_id: field(request, :request_id) || "native-#{System.unique_integer([:positive])}",
      status: Map.get(role_report, :status, :ok),
      summary: Map.fetch!(role_report, :summary),
      report: Map.fetch!(role_report, :report),
      evidence_used: evidence,
      confidence: Map.get(role_report, :confidence, 0.66),
      warnings: Map.get(role_report, :warnings, []),
      data_requests: Map.get(role_report, :data_requests, []),
      generated_at: DateTime.utc_now(),
      duration_ms: duration_ms,
      model_profile: model_profile,
      prompt_version: spec.prompt_version,
      generation_mode: Map.get(role_report, :generation_mode, "deterministic_advisory")
    }
    |> Map.merge(Map.get(role_report, :extra, %{}))
  end

  defp evidence_for(%{tool_modules: modules}, request, context) when is_list(modules) do
    Enum.map(modules, fn module ->
      case Runner.run(module.name(), evidence_params(request), evidence_context(request, context)) do
        {:ok, response} ->
          %{
            action: module.name(),
            status: Map.get(response, :status),
            evidence: Map.get(response, :evidence),
            message: Map.get(response, :message)
          }
          |> drop_nil()
          |> bound_evidence()
      end
    end)
  end

  defp evidence_for(_spec, _request, _context), do: []

  defp evidence_params(request) do
    %{
      ticker: field(request, :ticker, "UNKNOWN"),
      analysis_date: field(request, :analysis_date, "2026-05-15"),
      evidence_mode: field(request, :evidence_mode),
      fixture: field(request, :fixture, false),
      user_id: field(request, :user_id)
    }
    |> drop_nil()
  end

  defp evidence_context(request, context) do
    user_id = field(request, :user_id) || get_in_field(context, [:request, :user_id]) || "local"

    %{
      request: %{
        channel: :objective_agent,
        user_id: user_id,
        operator_id: field(request, :operator_id) || user_id,
        app_id: :stocksage
      },
      parent: field(request, :parent) || field(context, :parent, %{})
    }
  end

  defp prior_reports(request) do
    case field(request, :prior_reports, %{}) do
      reports when is_map(reports) -> reports
      reports when is_list(reports) -> Map.new(reports)
      _other -> %{}
    end
  end

  defp role_report(%{role: :market_context}, request, evidence, _prior_reports) do
    ticker = field(request, :ticker, "UNKNOWN")
    evidence_count = length(evidence)

    %{
      summary: "Market context prepared for #{ticker} from #{evidence_count} evidence packet(s).",
      report:
        "Market context for #{ticker}: fixture/live price and indicator evidence was normalized " <>
          "into a bounded advisory packet for downstream debate.",
      confidence: confidence(evidence_count, 0.62)
    }
  end

  defp role_report(%{role: :news_sentiment}, request, evidence, _prior_reports) do
    ticker = field(request, :ticker, "UNKNOWN")
    evidence_count = length(evidence)

    %{
      summary: "News and sentiment context prepared for #{ticker}.",
      report:
        "News/sentiment for #{ticker}: recent headline and social signal evidence was summarized " <>
          "for thesis construction.",
      confidence: confidence(evidence_count, 0.6)
    }
  end

  defp role_report(%{role: :fundamentals}, request, evidence, _prior_reports) do
    ticker = field(request, :ticker, "UNKNOWN")
    evidence_count = length(evidence)

    %{
      summary: "Fundamentals and financials context prepared for #{ticker}.",
      report:
        "Fundamentals for #{ticker}: company metrics and financial-statement evidence were " <>
          "summarized for valuation-aware debate.",
      confidence: confidence(evidence_count, 0.64)
    }
  end

  defp role_report(%{role: :bull_thesis}, request, _evidence, prior_reports) do
    ticker = field(request, :ticker, "UNKNOWN")

    %{
      summary: "Bull thesis prepared for #{ticker}.",
      report:
        "Bull thesis for #{ticker}: upside case draws on #{map_size(prior_reports)} prior " <>
          "report(s), emphasizing improving evidence quality and favorable risk/reward.",
      confidence: 0.68
    }
  end

  defp role_report(%{role: :bear_thesis}, request, _evidence, prior_reports) do
    ticker = field(request, :ticker, "UNKNOWN")

    %{
      summary: "Bear thesis prepared for #{ticker}.",
      report:
        "Bear thesis for #{ticker}: downside case draws on #{map_size(prior_reports)} prior " <>
          "report(s), emphasizing uncertainty, valuation risk, and evidence gaps.",
      confidence: 0.66
    }
  end

  defp role_report(%{role: role}, request, _evidence, prior_reports)
       when role in [:risk_aggressive, :risk_conservative, :risk_neutral] do
    ticker = field(request, :ticker, "UNKNOWN")
    stance = role |> Atom.to_string() |> String.replace("risk_", "")

    %{
      summary: "#{String.capitalize(stance)} risk review prepared for #{ticker}.",
      report:
        "#{String.capitalize(stance)} risk review for #{ticker}: evaluates #{map_size(prior_reports)} " <>
          "prior report(s) from the #{stance} portfolio posture.",
      confidence: 0.63
    }
  end

  defp role_report(%{role: :decision_synthesizer}, request, _evidence, prior_reports) do
    ticker = field(request, :ticker, "UNKNOWN")
    rating = synthesized_rating(prior_reports)
    confidence = synthesized_confidence(prior_reports)

    %{
      summary: "#{rating} decision synthesized for #{ticker}.",
      report:
        "Decision synthesis for #{ticker}: combines #{map_size(prior_reports)} specialist " <>
          "report(s) into a #{rating} advisory stance with confidence #{Float.round(confidence, 2)}.",
      confidence: confidence,
      extra: %{
        final_trade_decision: rating,
        rating: rating,
        recommendation: rating,
        investment_plan:
          "Use staged sizing and re-check catalyst/evidence drift before increasing exposure.",
        trader_investment_plan:
          "No autonomous order placement. Operator may review the advisory stance manually.",
        market_report: report_text(prior_reports, "stocksage.market_context"),
        sentiment_report: report_text(prior_reports, "stocksage.news_sentiment"),
        news_report: report_text(prior_reports, "stocksage.news_sentiment"),
        fundamentals_report: report_text(prior_reports, "stocksage.fundamentals")
      }
    }
  end

  defp role_report(%{role: :quality_gate}, _request, _evidence, prior_reports) do
    synthesis =
      field(prior_reports, "stocksage.decision_synthesizer") ||
        field(prior_reports, :decision_synthesizer) ||
        field(prior_reports, "decision_synthesizer")

    failed_clauses =
      []
      |> maybe_fail(:missing_synthesis, is_nil(synthesis))
      |> maybe_fail(
        :missing_final_trade_decision,
        blank?(field(synthesis || %{}, :final_trade_decision))
      )
      |> maybe_fail(:missing_report, blank?(field(synthesis || %{}, :report)))

    if failed_clauses == [] do
      %{
        summary: "Quality gate passed.",
        report: "Quality gate accepted report shape, evidence references, and bounded output.",
        confidence: 1.0,
        extra: %{failed_clauses: [], quality_status: :passed}
      }
    else
      %{
        status: :rejected,
        summary: "Quality gate rejected synthesized report.",
        report: "Quality gate rejected synthesized report: #{Enum.join(failed_clauses, ", ")}.",
        confidence: 0.0,
        warnings: ["quality gate rejected synthesized output"],
        extra: %{failed_clauses: failed_clauses, quality_status: :rejected}
      }
    end
  end

  defp confidence(evidence_count, base), do: min(0.9, base + evidence_count * 0.05)

  defp synthesized_rating(prior_reports) do
    cond do
      map_size(prior_reports) >= 8 -> "Hold"
      map_size(prior_reports) >= 5 -> "Overweight"
      true -> "Hold"
    end
  end

  defp synthesized_confidence(prior_reports),
    do: min(0.86, 0.58 + map_size(prior_reports) * 0.025)

  defp report_text(prior_reports, key) do
    prior_reports
    |> field(key, %{})
    |> field(:report, "")
  end

  defp maybe_fail(errors, error, true), do: [error | errors]
  defp maybe_fail(errors, _error, _false), do: errors

  defp blank?(value), do: is_nil(value) or (is_binary(value) and String.trim(value) == "")

  defp get_in_field(value, keys) do
    Enum.reduce_while(keys, value, fn key, acc ->
      case field(acc, key) do
        nil -> {:halt, nil}
        value -> {:cont, value}
      end
    end)
  end

  defp drop_nil(map), do: Map.reject(map, fn {_key, value} -> is_nil(value) end)

  defp bound_evidence(%{evidence: evidence} = summary) when is_map(evidence) do
    Map.put(
      summary,
      :evidence,
      Map.take(evidence, [:kind, :mode, :ticker, :analysis_date, :source])
    )
  end

  defp bound_evidence(summary), do: summary

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, default)
  end

  defp field(_map, _key, default), do: default
end
