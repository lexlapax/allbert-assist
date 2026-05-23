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

  @impl true
  def app_id, do: :stocksage

  @impl true
  def display_name, do: "StockSage"

  @impl true
  # v0.31 closeout: release-pinned after StockSage app and workspace cards
  # moved onto the shared Surface catalog/renderer path.
  # Convention is documented in DEVELOPMENT.md "App version metadata".
  def version, do: "0.31.0"

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
      %Surface{
        id: :stocksage_workspace,
        app_id: :stocksage,
        label: "StockSage",
        path: "/stocksage",
        kind: :workspace,
        status: :available,
        nodes: [
          %Node{
            id: "stocksage-workspace-root",
            component: :workspace,
            props: %{app: "stocksage", region: "workspace"},
            children: [
              %Node{
                id: "stocksage-workspace-header",
                component: :header,
                props: %{title: "StockSage", subtitle: "Financial analysis workspace"}
              },
              %Node{
                id: "stocksage-workspace-nav",
                component: :tabs,
                props: %{tabs: ["analyses", "queue", "trends"]}
              }
            ]
          }
        ],
        fallback_text: "StockSage workspace is available at /stocksage.",
        metadata: %{nav_order: 10, live_view: "StockSageWeb.WorkspaceLive"}
      },
      %Surface{
        id: :stocksage_analyses,
        app_id: :stocksage,
        label: "StockSage Analyses",
        path: "/stocksage/analyses",
        kind: :analysis,
        status: :available,
        nodes: [
          %Node{
            id: "stocksage-analyses-root",
            component: :section,
            props: %{region: "analyses"},
            children: [
              %Node{
                id: "stocksage-analyses-empty",
                component: :empty_state,
                props: %{
                  title: "No analyses selected",
                  body: "StockSage analyses will render here."
                }
              }
            ]
          }
        ],
        fallback_text: "StockSage analyses are available at /stocksage/analyses.",
        metadata: %{nav_order: 20, live_view: "StockSageWeb.AnalysisLive"}
      },
      %Surface{
        id: :stocksage_queue,
        app_id: :stocksage,
        label: "StockSage Queue",
        path: "/stocksage/queue",
        kind: :analysis,
        status: :available,
        nodes: [
          %Node{
            id: "stocksage-queue-root",
            component: :list,
            props: %{region: "queue", empty?: true}
          }
        ],
        fallback_text: "StockSage queue is available at /stocksage/queue.",
        metadata: %{nav_order: 30, live_view: "StockSageWeb.QueueLive"}
      },
      %Surface{
        id: :stocksage_trends,
        app_id: :stocksage,
        label: "StockSage Trends",
        path: "/stocksage/trends",
        kind: :analysis,
        status: :available,
        nodes: [
          %Node{
            id: "stocksage-trends-root",
            component: :table,
            props: %{region: "trends", empty?: true}
          }
        ],
        fallback_text: "StockSage trends are available at /stocksage/trends.",
        metadata: %{nav_order: 40, live_view: "StockSageWeb.TrendsLive"}
      }
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
end
