defmodule StockSage.SurfaceNodes do
  @moduledoc """
  Builds validated StockSage Surface nodes for app-owned LiveView rendering.
  """

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias StockSage.Actions

  @max_summary 500
  @max_warning 240

  @spec completed(map(), map(), map(), map(), String.t(), non_neg_integer(), boolean(), boolean()) ::
          {:ok, [Node.t()]} | {:error, [map()]}
  def completed(analysis, validated, result, context, summary, duration_ms, stub?, truncated?) do
    nodes =
      [
        analysis_node(
          analysis,
          validated,
          result,
          context,
          summary,
          duration_ms,
          stub?,
          truncated?
        )
      ] ++
        agent_report_nodes(validated, result) ++
        debate_round_nodes(validated, result) ++
        parity_nodes(validated, result)

    validate_nodes(nodes)
  end

  @spec failed(String.t() | nil, map(), map(), String.t(), non_neg_integer()) ::
          {:ok, [Node.t()]} | {:error, [map()]}
  def failed(analysis_id, validated, context, reason, duration_ms) do
    validate_nodes([
      node("analysis-failed-#{safe_id(analysis_id || validated.ticker)}", :analysis_card, %{
        analysis_id: analysis_id,
        ticker: validated.ticker,
        symbol: validated.ticker,
        analysis_date: Date.to_iso8601(validated.analysis_date),
        engine: validated.engine,
        status: "failed",
        summary: bounded(reason, @max_summary),
        warnings: [bounded(reason, @max_warning)],
        objective_id: validated.objective_id,
        step_id: validated.step_id,
        trace_id: Actions.field(context, :trace_id),
        duration_ms: duration_ms,
        route: analysis_route(analysis_id)
      })
    ])
  end

  @spec from_analysis(map()) :: {:ok, [Node.t()]} | {:error, [map()]}
  def from_analysis(analysis) when is_map(analysis) do
    nodes =
      [
        node("analysis-#{safe_id(Map.get(analysis, :id))}", :analysis_card, %{
          analysis_id: Map.get(analysis, :id),
          ticker: Map.get(analysis, :symbol),
          symbol: Map.get(analysis, :symbol),
          analysis_date: date_value(Map.get(analysis, :analysis_date)),
          engine: Map.get(analysis, :engine),
          status: Map.get(analysis, :status),
          rating: Map.get(analysis, :recommendation),
          recommendation: Map.get(analysis, :recommendation),
          summary: bounded(Map.get(analysis, :summary), @max_summary),
          objective_id: Map.get(analysis, :objective_id),
          step_id: Map.get(analysis, :step_id),
          trace_id: Map.get(analysis, :trace_id),
          route: analysis_route(Map.get(analysis, :id))
        })
      ] ++
        persisted_detail_nodes(Map.get(analysis, :details, []), Map.get(analysis, :parity_diff))

    validate_nodes(nodes)
  end

  @spec validate_nodes([Node.t()]) :: {:ok, [Node.t()]} | {:error, [map()]}
  def validate_nodes(nodes) when is_list(nodes) do
    with :ok <- validate_declared_components(nodes),
         {:ok, surface} <- Surface.validate_surface(validation_surface(nodes)) do
      {:ok, surface.nodes}
    else
      {:error, diagnostics} when is_list(diagnostics) -> {:error, diagnostics}
      {:error, reason} -> {:error, [diagnostic(:invalid_surface_nodes, inspect(reason))]}
    end
  end

  def validate_nodes(_nodes),
    do: {:error, [diagnostic(:invalid_surface_nodes, "Surface nodes must be a list.")]}

  defp analysis_node(
         analysis,
         validated,
         result,
         context,
         summary,
         duration_ms,
         stub?,
         truncated?
       ) do
    node("analysis-#{safe_id(analysis.id)}", :analysis_card, %{
      analysis_id: analysis.id,
      ticker: analysis.symbol || validated.ticker,
      symbol: analysis.symbol || validated.ticker,
      analysis_date: Date.to_iso8601(validated.analysis_date),
      engine: validated.engine,
      status: analysis.status || "completed",
      rating: result_field(result, :recommendation) || Map.get(analysis, :recommendation),
      recommendation: result_field(result, :recommendation) || Map.get(analysis, :recommendation),
      confidence: result_field(result, :confidence),
      summary: bounded(summary, @max_summary),
      warnings: warnings(result_field(result, :warnings, [])),
      objective_id: validated.objective_id,
      step_id: validated.step_id,
      trace_id: Actions.field(context, :trace_id),
      duration_ms: duration_ms,
      truncated: truncated?,
      stub: stub?,
      route: analysis_route(analysis.id)
    })
  end

  defp agent_report_nodes(%{engine: engine}, result) when engine in ["native", "both"] do
    result
    |> native_report(engine)
    |> result_field(:agent_reports, %{})
    |> case do
      reports when is_map(reports) ->
        reports
        |> Enum.sort_by(fn {agent_id, _report} -> to_string(agent_id) end)
        |> Enum.take(12)
        |> Enum.map(fn {agent_id, report} ->
          node("agent-report-#{safe_id(agent_id)}", :agent_report_card, %{
            agent: agent_id,
            role: result_field(report, :role),
            status: result_field(report, :status, "completed"),
            rating: result_field(report, :rating),
            confidence: result_field(report, :confidence),
            summary: bounded(result_field(report, :summary), @max_summary),
            generation_mode: result_field(report, :generation_mode),
            warnings: warnings(result_field(report, :warnings, []))
          })
        end)

      _other ->
        []
    end
  end

  defp agent_report_nodes(_validated, _result), do: []

  defp debate_round_nodes(%{engine: engine}, result) when engine in ["native", "both"] do
    result
    |> native_report(engine)
    |> result_field(:debate_rounds, [])
    |> List.wrap()
    |> Enum.take(4)
    |> Enum.flat_map(&round_nodes/1)
  end

  defp debate_round_nodes(_validated, _result), do: []

  defp parity_nodes(%{engine: engine}, result) when engine in ["both", "native"] do
    case result_field(result, :parity_diff) do
      parity_diff when is_map(parity_diff) ->
        [
          node("parity-#{safe_id(result_field(result, :request_id, "result"))}", :parity_card, %{
            status: "completed",
            native_status: result_field(parity_diff, :native_status),
            python_status: result_field(parity_diff, :python_status),
            native_rating: result_field(parity_diff, :native_rating),
            python_rating: result_field(parity_diff, :python_rating),
            rating_agreement: result_field(parity_diff, :rating_agreement),
            native_confidence: result_field(parity_diff, :native_confidence),
            python_confidence: result_field(parity_diff, :python_confidence),
            confidence_delta: result_field(parity_diff, :confidence_delta),
            parity_pass: result_field(parity_diff, :parity_pass),
            native_error: result_field(parity_diff, :native_error),
            python_error: result_field(parity_diff, :python_error),
            summary: "Native/Python parity metadata recorded."
          })
        ]

      _other ->
        []
    end
  end

  defp parity_nodes(_validated, _result), do: []

  defp persisted_detail_nodes(details, parity_diff_json) do
    details
    |> List.wrap()
    |> Enum.flat_map(fn detail ->
      payload = Map.get(detail, :payload) || %{}
      native_report = result_field(payload, :native_report, %{})

      agent_report_nodes(%{engine: "native"}, native_report) ++
        debate_round_nodes(%{engine: "native"}, native_report) ++
        persisted_parity_nodes(payload, parity_diff_json)
    end)
  end

  defp persisted_parity_nodes(payload, parity_diff_json) do
    parity_diff =
      result_field(payload, :parity_diff) ||
        decode_json_map(parity_diff_json)

    case parity_diff do
      parity_diff when is_map(parity_diff) ->
        [
          node("parity-persisted", :parity_card, %{
            status: "completed",
            native_status: result_field(parity_diff, :native_status),
            python_status: result_field(parity_diff, :python_status),
            native_rating: result_field(parity_diff, :native_rating),
            python_rating: result_field(parity_diff, :python_rating),
            rating_agreement: result_field(parity_diff, :rating_agreement),
            confidence_delta: result_field(parity_diff, :confidence_delta),
            parity_pass: result_field(parity_diff, :parity_pass),
            summary: "Native/Python parity metadata recorded."
          })
        ]

      _other ->
        []
    end
  end

  defp round_nodes(round) when is_map(round) do
    round_index = result_field(round, :round_index, 1)

    [
      debate_node(round_index, "bull", "bull_thesis", result_field(round, :bull)),
      debate_node(round_index, "bear", "bear_thesis", result_field(round, :bear))
      | risk_nodes(round_index, result_field(round, :risks, []))
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp round_nodes(_round), do: []

  defp debate_node(_round_index, _side, _agent, nil), do: nil

  defp debate_node(round_index, side, agent, report) do
    node(
      "debate-#{safe_id(side)}-#{safe_id(agent)}-#{safe_id(round_index)}",
      :debate_round_card,
      %{
        round: round_index,
        side: side,
        agent: agent,
        status: result_field(report, :status, "completed"),
        rating: result_field(report, :rating),
        summary: bounded(result_field(report, :summary), @max_summary),
        warnings: warnings(result_field(report, :warnings, []))
      }
    )
  end

  defp risk_nodes(round_index, risks) do
    risks
    |> List.wrap()
    |> Enum.take(3)
    |> Enum.with_index(1)
    |> Enum.map(fn {report, index} ->
      debate_node(round_index, "risk", "risk_#{index}", report)
    end)
  end

  defp validate_declared_components(nodes) do
    declared_components =
      StockSage.App.surface_catalog()
      |> MapSet.new(& &1.component)

    undeclared =
      nodes
      |> flatten_nodes()
      |> Enum.map(& &1.component)
      |> Enum.reject(&MapSet.member?(declared_components, &1))
      |> Enum.uniq()

    case undeclared do
      [] ->
        :ok

      components ->
        {:error,
         [
           diagnostic(
             :undeclared_surface_component,
             "Surface node uses component not declared by StockSage.App.surface_catalog/0.",
             %{components: components}
           )
         ]}
    end
  end

  defp validation_surface(nodes) do
    %Surface{
      id: :stocksage_run_analysis_result,
      app_id: :stocksage,
      label: "StockSage Analysis Result",
      path: "/stocksage/analyses",
      kind: :analysis,
      status: :available,
      fallback_text: "StockSage analysis result.",
      nodes: nodes,
      metadata: %{source: "stocksage.run_analysis"}
    }
  end

  defp node(id, component, props) do
    %Node{
      id: id |> to_string() |> String.slice(0, 64),
      component: component,
      props: props |> drop_nil_values() |> bounded_props()
    }
  end

  defp native_report(result, "both"), do: result_field(result, :native_report, %{})
  defp native_report(result, _engine), do: result

  defp result_field(result, key, default \\ nil)

  defp result_field(result, key, default) when is_map(result) and is_atom(key) do
    Map.get(result, key, Map.get(result, Atom.to_string(key), default))
  end

  defp result_field(_result, _key, default), do: default

  defp warnings(value) when is_list(value) do
    value
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&bounded(&1, @max_warning))
    |> Enum.take(6)
  end

  defp warnings(value), do: warnings(List.wrap(value))

  defp bounded(nil, _limit), do: nil
  defp bounded(value, limit) when is_binary(value), do: String.slice(value, 0, limit)

  defp bounded(value, limit),
    do: value |> inspect(limit: 20, printable_limit: limit) |> bounded(limit)

  defp bounded_props(props) do
    props
    |> Enum.take(64)
    |> Map.new(fn {key, value} -> {key, bounded_value(value)} end)
  end

  defp bounded_value(value) when is_binary(value), do: String.slice(value, 0, 2_000)

  defp bounded_value(value) when is_list(value),
    do: value |> Enum.take(16) |> Enum.map(&bounded_value/1)

  defp bounded_value(value) when is_map(value), do: value |> drop_nil_values() |> bounded_props()
  defp bounded_value(value), do: value

  defp flatten_nodes(nodes) do
    Enum.flat_map(nodes, fn %Node{} = node -> [node | flatten_nodes(node.children)] end)
  end

  defp drop_nil_values(map) when is_map(map) do
    map
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  defp analysis_route(nil), do: nil
  defp analysis_route(analysis_id), do: "/stocksage/analyses/#{safe_id(analysis_id)}"

  defp date_value(%Date{} = date), do: Date.to_iso8601(date)
  defp date_value(value), do: value

  defp decode_json_map(value) when is_binary(value) do
    case Jason.decode(value) do
      {:ok, %{} = map} -> map
      _other -> nil
    end
  end

  defp decode_json_map(_value), do: nil

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]/, "-")
    |> String.slice(0, 48)
  end

  defp diagnostic(kind, message, detail \\ %{}) do
    %{kind: kind, message: message, detail: detail}
  end
end
