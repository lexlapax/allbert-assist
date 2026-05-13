# Allbert D-Track M-Canvas: StockSage Canvas Integration

## Status

Research (unstarted). This plan file will be expanded when both v0.17 and
M-D3b are complete.

## Purpose

M-Canvas registers StockSage components with the allbert core v0.17 canvas
substrate. No new agent, domain, or data work — purely wiring existing
StockSage LiveView components into the allbert canvas catalog.

## Hard Prerequisites

- v0.17 shipped: canvas substrate, `AllbertAssist.Surface` catalog, and
  `AllbertAssist.App.SurfaceProvider` behaviour exist.
- M-D3b complete: StockSage LiveView components exist and are stable.
- M-AppContract-Full complete: `canvas_catalog/0` callback exists in the full
  contract (was deferred from M-AppContract-Full pending v0.17 shipping).

## Scope

- `StockSageWeb.Canvas.StockChart` — Phoenix.Component wrapping the chart
  LiveView surface.
- `StockSageWeb.Canvas.AnalysisCard` — summary tile for a completed analysis.
- `StockSage.App.canvas_components/0` callback implemented, returning
  `[{"stock_chart", StockSageWeb.Canvas.StockChart}, ...]`.
- Agent response format extended with `canvas_ops` for analysis results where
  useful.
- `WorkspaceLive` dashboard leverages canvas tiles for recent analysis
  summaries.

## Definition Of Done (high level)

- `mix allbert.ask --user alice "analyze AAPL"` triggers an analysis and
  pushes a `stock_chart` tile to the canvas.
- Tile survives page reload when `persist: true`.
- Canvas component catalog validation rejects model-invented component names
  that are not in the registered StockSage catalog.
