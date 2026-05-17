defmodule StockSage.Agents.NativeCoordinator.Commands.Analyze do
  @moduledoc """
  Native StockSage coordinator.

  M5 executes the full ten-agent graph with configurable bull/bear and risk
  debate rounds. Every specialist call remains visible through objective steps
  and native signals.
  """

  use Jido.Action,
    name: "stocksage_native_coordinator_analyze",
    description: "Run a single-round native StockSage analysis."

  alias AllbertAssist.Objectives
  alias AllbertAssist.Objectives.AgentRegistry
  alias AllbertAssist.Settings
  alias AllbertAssist.Signals, as: AllbertSignals
  alias Jido.Signal
  alias StockSage.Agents

  @impl true
  def run(params, _context) do
    request = normalize_request(params)

    case analyze(request) do
      {:ok, report} ->
        {:ok,
         %{
           active_runs: %{},
           last_command: :analyze,
           last_result: {:ok, report},
           last_error: nil,
           last_summary: Map.take(report, [:ticker, :analysis_date, :engine, :status])
         }}

      {:error, reason, partial_report} ->
        {:ok,
         %{
           active_runs: %{},
           last_command: :analyze,
           last_result: {:error, reason},
           last_error: inspect(reason),
           last_summary:
             partial_report
             |> Map.take([:ticker, :analysis_date, :engine, :status, :warnings])
             |> Map.put(:error, reason)
         }}
    end
  end

  defp analyze(request) do
    emit_native("allbert.stocksage.native.analysis_started", request, %{})

    {analyst_reports, analyst_warnings} =
      run_group(
        ["stocksage.market_context", "stocksage.news_sentiment", "stocksage.fundamentals"],
        request,
        %{},
        :analyst,
        1
      )

    {bull_reports, bull_warnings, bull_rounds} =
      run_bull_bear_rounds(request, analyst_reports, debate_round_count(request))

    {risk_reports, risk_warnings, risk_rounds} =
      run_risk_rounds(
        request,
        Map.merge(analyst_reports, bull_reports),
        risk_round_count(request)
      )

    prior_reports =
      %{}
      |> Map.merge(analyst_reports)
      |> Map.merge(bull_reports)
      |> Map.merge(risk_reports)

    {synth_reports, synth_warnings} =
      run_sequence(
        ["stocksage.decision_synthesizer"],
        request,
        prior_reports,
        :synthesis,
        1
      )

    synthesis = Map.get(synth_reports, "stocksage.decision_synthesizer")

    emit_native("allbert.stocksage.native.synthesis.completed", request, %{
      final_trade_decision: field(synthesis || %{}, :final_trade_decision),
      rating: field(synthesis || %{}, :rating),
      confidence: field(synthesis || %{}, :confidence)
    })

    quality_input =
      if field(request, :force_quality_reject) do
        prior_reports
      else
        Map.merge(prior_reports, synth_reports)
      end

    {quality_reports, quality_warnings} =
      run_sequence(["stocksage.quality_gate"], request, quality_input, :quality_gate, 1)

    quality = Map.get(quality_reports, "stocksage.quality_gate")

    warnings =
      analyst_warnings ++ bull_warnings ++ risk_warnings ++ synth_warnings ++ quality_warnings

    report =
      build_report(request, %{
        analyst_reports: analyst_reports,
        bull_reports: bull_reports,
        risk_reports: risk_reports,
        synth_reports: synth_reports,
        quality_reports: quality_reports,
        debate_rounds: merge_rounds(bull_rounds, risk_rounds),
        warnings: warnings
      })

    case field(quality || %{}, :status) do
      :ok ->
        emit_native("allbert.stocksage.native.quality_gate.passed", request, %{
          warnings: warnings
        })

        {:ok, report}

      "ok" ->
        emit_native("allbert.stocksage.native.quality_gate.passed", request, %{
          warnings: warnings
        })

        {:ok, report}

      _other ->
        failed_clauses = field(quality || %{}, :failed_clauses, [])

        emit_native("allbert.stocksage.native.quality_gate.rejected", request, %{
          rejection_reason: field(quality || %{}, :summary) || "quality gate rejected output",
          failed_clauses: failed_clauses
        })

        {:error, {:quality_gate_rejected, failed_clauses}, %{report | status: :failed}}
    end
  end

  defp run_group(agent_ids, request, prior_reports, stage, round_index) do
    agent_ids
    |> Task.async_stream(
      fn agent_id -> dispatch_agent(agent_id, request, prior_reports, stage, round_index) end,
      max_concurrency: length(agent_ids),
      timeout: :infinity
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, "unknown", {:task_exit, reason}}
    end)
    |> collect_results()
  end

  defp run_sequence(agent_ids, request, prior_reports, stage, round_index) do
    {reports, warnings} =
      Enum.reduce(agent_ids, {prior_reports, []}, fn agent_id, {acc, warnings} ->
        case dispatch_agent(agent_id, request, acc, stage, round_index) do
          {:ok, id, report} -> {Map.put(acc, id, report), warnings}
          {:error, id, reason} -> {acc, [warning(id, reason) | warnings]}
        end
      end)

    agent_reports = Map.take(reports, agent_ids)
    {agent_reports, Enum.reverse(warnings)}
  end

  defp run_bull_bear_rounds(request, prior_reports, max_rounds) do
    Enum.reduce(1..max_rounds, {%{}, [], []}, fn round_index, {reports, warnings, rounds} ->
      round_prior = Map.merge(prior_reports, reports)

      {round_reports, round_warnings} =
        run_sequence(
          ["stocksage.bull_thesis", "stocksage.bear_thesis"],
          request,
          round_prior,
          :bull_bear,
          round_index
        )

      emit_native("allbert.stocksage.native.debate_round.completed", request, %{
        round_index: round_index,
        role_class: :bull_bear
      })

      renamed = rename_round_reports(round_reports, round_index)

      round = %{
        round_index: round_index,
        bull: Map.get(round_reports, "stocksage.bull_thesis"),
        bear: Map.get(round_reports, "stocksage.bear_thesis")
      }

      {Map.merge(reports, renamed), warnings ++ round_warnings, [round | rounds]}
    end)
    |> then(fn {reports, warnings, rounds} -> {reports, warnings, Enum.reverse(rounds)} end)
  end

  defp run_risk_rounds(request, prior_reports, max_rounds) do
    risk_ids = [
      "stocksage.risk_aggressive",
      "stocksage.risk_conservative",
      "stocksage.risk_neutral"
    ]

    Enum.reduce(1..max_rounds, {%{}, [], []}, fn round_index, {reports, warnings, rounds} ->
      {round_reports, round_warnings} =
        run_group(risk_ids, request, Map.merge(prior_reports, reports), :risk, round_index)

      emit_native("allbert.stocksage.native.debate_round.completed", request, %{
        round_index: round_index,
        role_class: :risk
      })

      renamed = rename_round_reports(round_reports, round_index)

      round = %{
        round_index: round_index,
        risks: Enum.map(risk_ids, &Map.get(round_reports, &1)) |> Enum.reject(&is_nil/1)
      }

      {Map.merge(reports, renamed), warnings ++ round_warnings, [round | rounds]}
    end)
    |> then(fn {reports, warnings, rounds} -> {reports, warnings, Enum.reverse(rounds)} end)
  end

  defp rename_round_reports(reports, round_index) do
    Map.new(reports, fn {agent_id, report} -> {"#{agent_id}.round_#{round_index}", report} end)
  end

  defp dispatch_agent(agent_id, request, prior_reports, stage, round_index) do
    emit_native("allbert.stocksage.native.agent.dispatched", request, %{
      agent_id: agent_id,
      role: role(agent_id),
      round_index: round_index,
      stage: stage
    })

    step = create_step(request, agent_id, stage, round_index)

    if agent_id == field(request, :fail_agent_id) do
      reason = {:forced_agent_failure, agent_id}
      fail_step(step, reason)
      emit_failed(request, agent_id, round_index, reason)
      {:error, agent_id, reason}
    else
      params =
        request
        |> Map.put(:agent_id, agent_id)
        |> Map.put(:round_index, round_index)
        |> Map.put(:stage, stage)
        |> Map.put(:prior_reports, prior_reports)

      case AgentRegistry.dispatch(agent_id, :execute, params, timeout: :infinity) do
        {:ok, %{state: %{last_result: {:ok, report}}}} ->
          complete_step(step, report)
          emit_completed(request, agent_id, round_index, report)
          {:ok, agent_id, report}

        {:ok, %{state: %{"last_result" => {:ok, report}}}} ->
          complete_step(step, report)
          emit_completed(request, agent_id, round_index, report)
          {:ok, agent_id, report}

        {:ok, %{state: state}} ->
          reason = {:missing_agent_result, Map.take(state, [:last_error, "last_error"])}
          fail_step(step, reason)
          emit_failed(request, agent_id, round_index, reason)
          {:error, agent_id, reason}

        {:error, reason} ->
          fail_step(step, reason)
          emit_failed(request, agent_id, round_index, reason)
          {:error, agent_id, reason}
      end
    end
  end

  defp collect_results(results) do
    Enum.reduce(results, {%{}, []}, fn
      {:ok, id, report}, {reports, warnings} ->
        {Map.put(reports, id, report), warnings}

      {:error, id, reason}, {reports, warnings} ->
        {reports, [warning(id, reason) | warnings]}
    end)
    |> then(fn {reports, warnings} -> {reports, Enum.reverse(warnings)} end)
  end

  defp create_step(%{objective_id: objective_id} = request, agent_id, stage, round_index)
       when is_binary(objective_id) and objective_id != "" do
    attrs = %{
      objective_id: objective_id,
      parent_step_id: field(request, :step_id),
      kind: :delegate_agent,
      status: :running,
      stage: :execute_step,
      provider: "stocksage.native",
      delegate_agent_id: agent_id,
      trace_id: field(request, :trace_id),
      action_params: %{
        ticker: field(request, :ticker),
        analysis_date: field(request, :analysis_date),
        stage: stage,
        round_index: round_index
      }
    }

    case Objectives.create_step(attrs) do
      {:ok, step} -> step
      {:error, _reason} -> nil
    end
  end

  defp create_step(_request, _agent_id, _stage, _round_index), do: nil

  defp complete_step(nil, _report), do: :ok

  defp complete_step(step, report) do
    _ =
      Objectives.transition_step(step, :completed, %{
        result_summary: field(report, :summary),
        observation_summary: field(report, :report)
      })

    :ok
  end

  defp fail_step(nil, _reason), do: :ok

  defp fail_step(step, reason) do
    _ =
      Objectives.transition_step(step, :failed, %{
        result_summary: inspect(reason, limit: 20, printable_limit: 500)
      })

    :ok
  end

  defp build_report(request, parts) do
    agent_reports =
      %{}
      |> Map.merge(parts.analyst_reports)
      |> Map.merge(parts.bull_reports)
      |> Map.merge(parts.risk_reports)
      |> Map.merge(parts.synth_reports)
      |> Map.merge(parts.quality_reports)

    synthesis = Map.get(parts.synth_reports, "stocksage.decision_synthesizer", %{})

    %{
      status: :ok,
      engine: "native",
      request_id: field(request, :request_id) || "native-#{System.unique_integer([:positive])}",
      ticker: field(request, :ticker, "UNKNOWN"),
      analysis_date: field(request, :analysis_date),
      objective_id: field(request, :objective_id),
      step_id: field(request, :step_id),
      agent_ids: Agents.ids(),
      agent_reports: agent_reports,
      debate_rounds: parts.debate_rounds,
      final_trade_decision: field(synthesis, :final_trade_decision) || "Hold",
      recommendation: field(synthesis, :recommendation) || field(synthesis, :rating) || "Hold",
      confidence: field(synthesis, :confidence, 0.5),
      investment_plan: field(synthesis, :investment_plan),
      trader_investment_plan: field(synthesis, :trader_investment_plan),
      market_report: field(synthesis, :market_report),
      sentiment_report: field(synthesis, :sentiment_report),
      news_report: field(synthesis, :news_report),
      fundamentals_report: field(synthesis, :fundamentals_report),
      summary:
        field(synthesis, :summary) ||
          "Native StockSage analysis completed for #{field(request, :ticker, "UNKNOWN")}.",
      warnings: Enum.uniq(parts.warnings),
      generated_at: DateTime.utc_now()
    }
  end

  defp emit_completed(request, agent_id, round_index, report) do
    emit_native("allbert.stocksage.native.agent.completed", request, %{
      agent_id: agent_id,
      role: role(agent_id),
      round_index: round_index,
      status: field(report, :status),
      duration_ms: field(report, :duration_ms),
      confidence: field(report, :confidence)
    })
  end

  defp emit_failed(request, agent_id, round_index, reason) do
    emit_native("allbert.stocksage.native.agent.failed", request, %{
      agent_id: agent_id,
      role: role(agent_id),
      round_index: round_index,
      status: :error,
      error: inspect(reason, limit: 20, printable_limit: 500)
    })
  end

  defp emit_native(type, request, payload) do
    metadata =
      %{
        objective_id: field(request, :objective_id),
        step_id: field(request, :step_id),
        user_id: field(request, :user_id),
        ticker: field(request, :ticker),
        analysis_date: field(request, :analysis_date),
        engine: "native",
        trace_id: field(request, :trace_id),
        request_id: field(request, :request_id)
      }
      |> Map.merge(payload)

    case Signal.new(
           type,
           AllbertSignals.redact(metadata),
           source: "/allbert/stocksage/native",
           subject: field(request, :user_id)
         ) do
      {:ok, signal} -> AllbertSignals.log(signal)
      _other -> :ok
    end
  rescue
    _exception -> :ok
  end

  defp normalize_request(params) do
    %{
      request_id: field(params, :request_id) || "native-#{System.unique_integer([:positive])}",
      ticker: field(params, :ticker, "UNKNOWN"),
      analysis_date: field(params, :analysis_date),
      user_id: field(params, :user_id),
      operator_id: field(params, :operator_id) || field(params, :user_id),
      objective_id: field(params, :objective_id),
      step_id: field(params, :step_id),
      thread_id: field(params, :thread_id),
      session_id: field(params, :session_id),
      trace_id: field(params, :trace_id),
      evidence_mode: field(params, :evidence_mode),
      fixture: field(params, :fixture),
      parent: field(params, :parent, %{}),
      fail_agent_id: field(params, :fail_agent_id),
      force_quality_reject: field(params, :force_quality_reject),
      max_debate_rounds: field(params, :max_debate_rounds),
      max_risk_rounds: field(params, :max_risk_rounds)
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp role(agent_id) do
    case Agents.spec(agent_id) do
      {:ok, spec} -> spec.role
      {:error, :not_found} -> :unknown
    end
  end

  defp warning(agent_id, reason) do
    "#{agent_id}: #{inspect(reason, limit: 20, printable_limit: 240)}"
  end

  defp merge_rounds(bull_rounds, risk_rounds) do
    max_rounds = max(length(bull_rounds), length(risk_rounds))

    Enum.map(1..max_rounds, fn round_index ->
      bull =
        Enum.find(bull_rounds, &(&1.round_index == round_index)) || %{round_index: round_index}

      risk =
        Enum.find(risk_rounds, &(&1.round_index == round_index)) || %{round_index: round_index}

      Map.merge(bull, risk)
    end)
  end

  defp debate_round_count(request) do
    request
    |> field(:max_debate_rounds)
    |> bounded_round_setting("stocksage.native_max_debate_rounds", 2, 1, 5)
  end

  defp risk_round_count(request) do
    request
    |> field(:max_risk_rounds)
    |> bounded_round_setting("stocksage.native_max_risk_rounds", 1, 1, 3)
  end

  defp bounded_round_setting(value, _key, _default, min, max) when is_integer(value) do
    value |> max(min) |> min(max)
  end

  defp bounded_round_setting(value, key, default, min, max) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, ""} -> bounded_round_setting(parsed, key, default, min, max)
      _other -> bounded_round_setting(nil, key, default, min, max)
    end
  end

  defp bounded_round_setting(_value, key, default, min, max) do
    case Settings.get(key) do
      {:ok, value} when is_integer(value) -> value |> max(min) |> min(max)
      _other -> default
    end
  rescue
    _exception -> default
  end

  defp field(map, key, default \\ nil)

  defp field(map, key, default) when is_map(map) and is_atom(key) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp field(map, key, default) when is_map(map) and is_binary(key) do
    Map.get(map, key, default)
  end

  defp field(_map, _key, default), do: default
end
