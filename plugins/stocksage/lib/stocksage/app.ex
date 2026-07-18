defmodule StockSage.App do
  @moduledoc """
  Allbert app contract implementation for StockSage.

  v0.20 registers StockSage as a real app with no concrete web surfaces yet.
  v0.27 (formerly v0.25) fills in LiveView route surfaces through the same
  provider behaviour.
  """

  use AllbertAssist.App
  use AllbertAssist.App.SurfaceProvider

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias StockSage.{Analyses, Queue, SurfaceNodes}

  @default_user_id "local"
  @dashboard_panel_id :stocksage_dashboard_panel
  @recent_panel_id :stocksage_recent_analyses_panel
  @queue_panel_id :stocksage_queue_panel
  @trends_panel_id :stocksage_trends_panel

  @impl true
  def app_id, do: :stocksage

  @impl true
  def display_name, do: "StockSage"

  @impl true
  # v0.32 M6 moves StockSage dashboard/list/queue/trend UI into the shared
  # workspace panel substrate.
  # Convention is documented in DEVELOPMENT.md "App version metadata".
  def version, do: "0.35.0"

  @impl true
  def validate(_opts), do: :ok

  @impl AllbertAssist.App
  def actions, do: StockSage.Plugin.actions()

  @impl AllbertAssist.App
  def skill_paths, do: StockSage.Plugin.skill_paths()

  @impl AllbertAssist.App
  def memory_namespace do
    %{
      app_id: :stocksage,
      namespace: :stocksage,
      writable: true,
      description:
        "StockSage-owned analysis memory namespace; v0.29 writes require explicit lesson sync confirmation."
    }
  end

  @impl AllbertAssist.App
  def surfaces do
    [
      dashboard_panel([dashboard_card(0, 0, 0)]),
      recent_analyses_panel([
        empty_state("recent-empty", "No recent analyses", recent_empty_body())
      ]),
      queue_panel([empty_state("queue-empty", "No queued analyses", queue_empty_body())]),
      trends_panel([empty_state("trends-empty", "No outcome trends", trends_empty_body())])
    ]
  end

  @doc """
  Returns StockSage panels hydrated from existing read contexts.

  The host workspace calls this optional provider callback with the current
  runtime scope. The returned surfaces are still catalog validated by the host
  before rendering.
  """
  def workspace_panel_surfaces(context) when is_map(context) do
    user_id = context_value(context, :user_id) || @default_user_id
    analyses = Analyses.list_analyses(user_id, limit: 5)
    queue_entries = Queue.list_entries(user_id, limit: 5)
    trends = Analyses.summarize_trends(user_id, limit: 5)

    [
      dashboard_panel([dashboard_card(length(analyses), length(queue_entries), trends.returned)]),
      recent_analyses_panel(recent_analysis_nodes(analyses)),
      queue_panel(queue_nodes(queue_entries)),
      trends_panel(trend_nodes(trends))
    ]
  rescue
    exception ->
      [
        dashboard_panel([
          error_card(
            "stocksage-panel-error",
            "StockSage panels unavailable",
            Exception.message(exception)
          )
        ])
      ]
  end

  def surface_catalog do
    [
      %{component: :analysis_card, allowed_props: [], allowed_bindings: []},
      %{component: :agent_report_card, allowed_props: [], allowed_bindings: []},
      %{component: :parity_card, allowed_props: [], allowed_bindings: []},
      %{component: :debate_round_card, allowed_props: [], allowed_bindings: []}
    ]
  end

  def intent_descriptors do
    [
      %{
        app_id: :stocksage,
        action_name: "run_analysis",
        label: "Run StockSage analysis",
        examples: [
          "analyze AAPL",
          "run StockSage analysis for TSLA",
          "analyze CIEN"
        ],
        synonyms: [
          "analyze",
          "analyse",
          "stock analysis",
          "financial analysis",
          "stocksage"
        ],
        vocabulary: %{
          negative_phrases: [
            "show stock analysis",
            "show stocksage analysis",
            "open analysis",
            "analysis details"
          ]
        },
        required_slots: [:ticker],
        slot_extractors: %{ticker: :ticker_symbol},
        handoff_required?: true,
        # F5 Q3: StockSage is the bundled example plugin; keep its intents out of the
        # default router shortlist so a fresh install does not route general prompts here.
        routable_by_default?: false
      },
      %{
        app_id: :stocksage,
        action_name: "get_trends",
        label: "Show StockSage trends",
        examples: [
          "show StockSage trends",
          "show trends for AAPL",
          "get trends for TSLA"
        ],
        synonyms: [
          "show trends",
          "get trends",
          "outcome trends",
          "performance trends",
          "stock trends",
          "trends"
        ],
        required_slots: [],
        optional_slots: [:symbol],
        slot_extractors: %{symbol: :ticker_symbol},
        handoff_required?: true,
        # F5 Q3: StockSage is the bundled example plugin; keep its intents out of the
        # default router shortlist so a fresh install does not route general prompts here.
        routable_by_default?: false
      },
      %{
        app_id: :stocksage,
        action_name: "list_analyses",
        label: "List StockSage analyses",
        examples: [
          "list stock analyses",
          "show recent StockSage analyses",
          "what analyses have I run"
        ],
        synonyms: [
          "list analyses",
          "recent analyses",
          "stock analyses",
          "stocksage history"
        ],
        required_slots: [],
        handoff_required?: true,
        # F5 Q3: StockSage is the bundled example plugin; keep its intents out of the
        # default router shortlist so a fresh install does not route general prompts here.
        routable_by_default?: false
      },
      %{
        app_id: :stocksage,
        action_name: "show_analysis",
        label: "Show StockSage analysis",
        examples: [
          "show stock analysis AAPL",
          "show the StockSage analysis for MSFT",
          "open analysis details"
        ],
        synonyms: [
          "show analysis",
          "analysis details",
          "stock analysis details",
          "open analysis"
        ],
        required_slots: [],
        optional_slots: [:symbol],
        slot_extractors: %{symbol: :ticker_symbol},
        handoff_required?: true,
        # F5 Q3: StockSage is the bundled example plugin; keep its intents out of the
        # default router shortlist so a fresh install does not route general prompts here.
        routable_by_default?: false
      },
      %{
        app_id: :stocksage,
        action_name: "queue_analysis",
        label: "Queue StockSage analysis",
        examples: [
          "queue analysis for AAPL",
          "queue StockSage analysis for TSLA",
          "add CIEN to the StockSage queue"
        ],
        synonyms: [
          "queue analysis",
          "queue stocksage analysis",
          "add to stocksage queue",
          "add to queue"
        ],
        required_slots: [:symbol],
        slot_extractors: %{symbol: :ticker_symbol},
        handoff_required?: true,
        # F5 Q3: StockSage is the bundled example plugin; keep its intents out of the
        # default router shortlist so a fresh install does not route general prompts here.
        routable_by_default?: false
      }
    ]
  end

  defp dashboard_panel(children),
    do: panel(@dashboard_panel_id, "StockSage dashboard", :canvas_panels, 100, children)

  defp recent_analyses_panel(children),
    do: panel(@recent_panel_id, "Recent analyses", :canvas_panels, 110, children)

  defp queue_panel(children),
    do: panel(@queue_panel_id, "Analysis queue", :canvas_panels, 120, children)

  defp trends_panel(children),
    do: panel(@trends_panel_id, "Outcome trends", :canvas_panels, 130, children)

  defp panel(id, label, zone, order, children) do
    %Surface{
      id: id,
      app_id: :stocksage,
      label: label,
      path: "/workspace",
      kind: :panel,
      zone: zone,
      status: :available,
      nodes: [
        %Node{
          id: panel_root_id(id),
          component: :panel,
          props: %{title: label, body: "StockSage #{zone_label(zone)} panel", status: "ready"},
          children: children
        }
      ],
      fallback_text: "#{label} is available from the StockSage workspace panels.",
      metadata: %{zone: zone, visible_when: :selected_app, order: order}
    }
  end

  defp dashboard_card(analysis_count, queued_count, outcome_count) do
    node("dashboard-summary", :analysis_card, %{
      title: "StockSage dashboard",
      ticker: "PORTFOLIO",
      symbol: "PORTFOLIO",
      engine: "workspace",
      status: "ready",
      recommendation: "review",
      summary:
        "#{analysis_count} recent analyses, #{queued_count} queued runs, #{outcome_count} observed outcomes."
    })
  end

  defp recent_analysis_nodes([]),
    do: [empty_state("recent-empty", "No recent analyses", recent_empty_body())]

  defp recent_analysis_nodes(analyses) do
    analyses
    |> Enum.flat_map(&analysis_preview_nodes/1)
    |> case do
      [] -> [empty_state("recent-empty", "No renderable analyses", recent_empty_body())]
      nodes -> nodes
    end
  end

  defp analysis_preview_nodes(analysis) do
    case SurfaceNodes.from_analysis(analysis) do
      {:ok, nodes} ->
        nodes
        |> Enum.filter(&match?(%Node{component: :analysis_card}, &1))
        |> Enum.map(&with_analysis_title(&1, analysis))

      {:error, _diagnostics} ->
        [
          error_card(
            "analysis-error-#{safe_id(value(analysis, :id) || "unknown")}",
            "Analysis preview unavailable",
            "StockSage could not render this persisted analysis summary."
          )
        ]
    end
  end

  defp with_analysis_title(%Node{} = node, analysis) do
    symbol = value(analysis, :symbol) || "StockSage"
    %{node | props: Map.put(node.props || %{}, :title, "#{symbol} analysis")}
  end

  defp queue_nodes([]), do: [empty_state("queue-empty", "No queued analyses", queue_empty_body())]

  defp queue_nodes(entries) do
    Enum.map(entries, fn entry ->
      symbol = value(entry, :symbol) || "UNKNOWN"

      node("queue-#{safe_id(value(entry, :id))}", :analysis_card, %{
        title: "#{symbol} queued analysis",
        ticker: symbol,
        symbol: symbol,
        engine: "queue",
        status: value(entry, :status) || "queued",
        recommendation: value(entry, :priority) || "normal",
        summary: queue_summary(entry),
        trace_id: value(entry, :trace_id)
      })
    end)
  end

  defp trend_nodes(%{returned: 0}),
    do: [empty_state("trends-empty", "No outcome trends", trends_empty_body())]

  defp trend_nodes(trends) when is_map(trends) do
    [
      node("trends-summary", :analysis_card, %{
        title: "StockSage outcome trends",
        ticker: "PORTFOLIO",
        symbol: "PORTFOLIO",
        engine: "outcomes",
        status: "observed",
        recommendation: trend_rating(trends),
        summary: trends_summary(trends)
      })
    ]
  end

  defp empty_state(id, title, body) do
    node(id, :empty_state, %{title: title, body: body})
  end

  defp error_card(id, title, reason) do
    node(id, :analysis_card, %{
      title: title,
      ticker: "STOCKSAGE",
      symbol: "STOCKSAGE",
      engine: "workspace",
      status: "failed",
      recommendation: "retry",
      summary: safe_text(reason, 500)
    })
  end

  defp node(id, component, props) do
    %Node{id: id, component: component, props: props}
  end

  defp queue_summary(entry) do
    requested_for =
      case value(entry, :requested_for) do
        %Date{} = date -> Date.to_iso8601(date)
        nil -> "unscheduled"
        requested_for -> to_string(requested_for)
      end

    "priority=#{value(entry, :priority) || "normal"} requested_for=#{requested_for}"
  end

  defp trends_summary(trends) do
    counts =
      trends
      |> Map.get(:counts, %{})
      |> Enum.sort_by(fn {label, _count} -> label end)
      |> Enum.map_join(", ", fn {label, count} -> "#{label}=#{count}" end)

    accuracy = Map.get(trends, :accuracy, %{})
    win_rate = Map.get(accuracy, :win_rate, 0.0)
    average_return = Map.get(accuracy, :avg_return_pct)

    "returned=#{Map.get(trends, :returned, 0)} win_rate=#{win_rate}% avg_return=#{average_return || "n/a"} counts=#{counts}"
  end

  defp trend_rating(trends) do
    case get_in(trends, [:accuracy, :win_rate]) do
      win_rate when is_number(win_rate) -> "#{win_rate}% win rate"
      _win_rate -> "pending"
    end
  end

  defp recent_empty_body,
    do: "Completed or failed analyses appear here after StockSage records them."

  defp queue_empty_body, do: "Queued StockSage runs appear here after they are requested."

  defp trends_empty_body,
    do: "Resolved outcomes appear here after StockSage records observations."

  defp panel_root_id(@dashboard_panel_id), do: "dashboard"
  defp panel_root_id(@recent_panel_id), do: "recent"
  defp panel_root_id(@queue_panel_id), do: "queue"
  defp panel_root_id(@trends_panel_id), do: "trends"

  defp zone_label(:canvas_panels), do: "canvas"

  defp context_value(context, key),
    do: AllbertAssist.Maps.field_truthy(context, key)

  defp value(map, key) when is_map(map) and is_atom(key),
    do: AllbertAssist.Maps.field_truthy(map, key)

  defp value(_map, _key), do: nil

  defp safe_text(value, max) do
    value
    |> to_string()
    |> String.replace_prefix("<", " ")
    |> String.replace_prefix("http://", "URL ")
    |> String.replace_prefix("https://", "URL ")
    |> String.slice(0, max)
  end

  defp safe_id(nil), do: "unknown"

  defp safe_id(value) do
    value
    |> to_string()
    |> String.replace(~r/[^a-zA-Z0-9_-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 48)
    |> case do
      "" -> "unknown"
      id -> id
    end
  end
end
