defmodule StockSage.AppPanelsTest do
  use StockSage.DataCase

  alias AllbertAssist.Surface
  alias AllbertAssist.Surface.Node
  alias StockSage.{Analyses, App, Queue}

  test "static surfaces declare workspace-only selected-app panels" do
    surfaces = App.surfaces()

    assert Enum.map(surfaces, & &1.id) == [
             :stocksage_dashboard_panel,
             :stocksage_recent_analyses_panel,
             :stocksage_queue_panel,
             :stocksage_trends_panel
           ]

    assert Enum.all?(surfaces, &match?(%Surface{path: "/workspace", kind: :panel}, &1))
    assert Enum.all?(surfaces, &(&1.metadata.visible_when == :selected_app))
    assert Enum.all?(surfaces, &(&1.zone == :canvas_panels))
    assert Enum.all?(surfaces, &(&1.metadata.zone == :canvas_panels))

    assert Enum.all?(
             surfaces,
             &(Surface.validate_surface_catalog(&1, App.surface_catalog()) == :ok)
           )
  end

  test "hydrated workspace panels render empty states without StockSage rows" do
    surfaces = App.workspace_panel_surfaces(%{user_id: "alice"})

    assert %Node{component: :analysis_card} =
             find_child(surfaces, :stocksage_dashboard_panel, :analysis_card)

    assert %Node{component: :empty_state, props: %{title: "No recent analyses"}} =
             find_child(surfaces, :stocksage_recent_analyses_panel, :empty_state)

    assert %Node{component: :empty_state, props: %{title: "No queued analyses"}} =
             find_child(surfaces, :stocksage_queue_panel, :empty_state)

    assert %Node{component: :empty_state, props: %{title: "No outcome trends"}} =
             find_child(surfaces, :stocksage_trends_panel, :empty_state)
  end

  test "hydrated workspace panels use StockSage read contexts and card renderers" do
    assert {:ok, analysis} =
             Analyses.create_analysis(%{
               user_id: "alice",
               symbol: "aapl",
               source: "manual",
               status: "completed",
               engine: "native",
               recommendation: "Buy",
               summary: "Constructive setup."
             })

    assert {:ok, _queue_entry} =
             Queue.create_entry(%{
               user_id: "alice",
               symbol: "msft",
               priority: "high",
               requested_for: ~D[2026-05-23]
             })

    assert {:ok, _outcome} =
             Analyses.create_outcome(%{
               user_id: "alice",
               analysis_id: analysis.id,
               symbol: "aapl",
               label: "win",
               return_pct: Decimal.new("4.2")
             })

    surfaces = App.workspace_panel_surfaces(%{user_id: "alice"})

    assert Enum.all?(
             surfaces,
             &(Surface.validate_surface_catalog(&1, App.surface_catalog()) == :ok)
           )

    assert %Node{props: %{summary: dashboard_summary}} =
             find_child(surfaces, :stocksage_dashboard_panel, :analysis_card)

    assert dashboard_summary =~ "1 recent analyses"
    assert dashboard_summary =~ "1 queued runs"
    assert dashboard_summary =~ "1 observed outcomes"

    assert %Node{props: %{title: "AAPL analysis", summary: "Constructive setup."}} =
             find_child(surfaces, :stocksage_recent_analyses_panel, :analysis_card)

    assert %Node{props: %{title: "MSFT queued analysis", recommendation: "high"}} =
             find_child(surfaces, :stocksage_queue_panel, :analysis_card)

    assert %Node{props: %{summary: trends_summary}} =
             find_child(surfaces, :stocksage_trends_panel, :analysis_card)

    assert trends_summary =~ "returned=1"
    assert trends_summary =~ "win=1"
  end

  defp find_child(surfaces, surface_id, component) do
    surfaces
    |> Enum.find(&(&1.id == surface_id))
    |> then(fn %Surface{nodes: [%Node{children: children}]} -> children end)
    |> Enum.find(&(&1.component == component))
  end
end
