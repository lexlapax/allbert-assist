# AllbertAssistWeb

Phoenix web surface for Allbert Assist.

Start the web demo:

```sh
export ALLBERT_HOME=/tmp/allbert-v006-demo
export ALLBERT_TRACE_ENABLED=true
mix phx.server
```

Open:

```text
http://localhost:4000/workspace
http://localhost:4000/workspace?app_id=stocksage
http://localhost:4000/apps/stocksage/analyses/<analysis_id>
http://localhost:4000/jobs
```

The `/workspace` LiveView is the v0.32 Allbert workspace. It renders
`AllbertAssist.App.CoreApp`'s Surface tree through catalog-dispatched
LiveComponents: chat, persistent per-thread canvas tiles, task-scoped
ephemeral surfaces, objective/status badges, trace cards, confirmation cards,
Settings Central, app launcher, mobile tabs, and offline text/markdown tile
editors.
Workspace effects still cross the same runtime/action boundary as the CLI:
registered actions, `Actions.Runner.run/3`, Security Central, Settings
Central, traces, and Allbert Home remain authoritative.
The old `/agent`, `/settings`, and `/stocksage/*` operator routes are absent
in v0.32 rather than redirected.

v0.23 was an internal Jido state-machine convergence release. It did not add a
new web surface; the current web surface still calls the same runtime,
settings, security, confirmation, and jobs boundaries. Default trace output
remains unchanged; `## Jido Debug` appears only when
`allbert.jido.debug_trace` is explicitly enabled.

v0.26 made the workspace substantially richer: the page owns rendering and
browser APIs, not runtime authority. The browser-side Yjs + IndexedDB editor
stores local drafts and sends bounded snapshots to the workspace facade;
server-side reconciliation records canvas revisions and surfaces
conflict/revert UI. Rejected or corrupt local drafts are retained in browser
storage with fallback-shell recovery metadata rather than discarded.

v0.27 added plugin-owned StockSage app surfaces under `/stocksage/*`. v0.32
moves StockSage dashboard, recent analyses, queue, and trends into
catalog-validated `/workspace` panels declared by `StockSage.App.surfaces/0`.
The retained long-form detail route is `/apps/stocksage/analyses/:id`.

v0.30 wires those same StockSage cards into durable workspace canvas tiles.
`RunAnalysis` lifecycle signals flow through
`AllbertAssist.Workspace.Emitters.stocksage_signal/2`, signed
`Workspace.Fragment.Envelope` validation, and the existing
`workspace_canvas_tiles` + YAML body store. The web renderer adapts the
v0.27 `StockSageWeb.Components.Cards` functions; it does not reintroduce the
v0.26 stubs or add a new `:stock_chart` component atom.
