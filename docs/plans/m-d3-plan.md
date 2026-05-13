# Allbert D-Track M-D3: StockSage Web Surface

## Status

Planning. Full spec lives in `docs/plans/aiworkspace-plan.md` §4 (D3) and §11
(M-D3a, M-D3b milestones). This plan file will be expanded to
implementation-ready detail when M-D2b and M-AppContract-Lite are complete.

## Purpose

M-D3 adds the web-based StockSage UI inside the Allbert shell as standard
LiveViews. No canvas integration yet — that is M-Canvas, which depends on
v0.17 shipping first.

- **M-D3a** — Four LiveViews: Workspace, Analysis, Queue, Trends. Real-time
  progress via PubSub. `active_app: :stocksage` set in session scratchpad.
- **M-D3b** — Full parity with Python StockSage 0.0.2: outcome resolver,
  memory sync, trends dashboard, mobile-responsive layout, error states.

## Hard Prerequisites

- M-D2b complete (bridge produces real analyses that the LiveViews display).
- M-AppContract-Lite complete (StockSage registered; routes mounted via
  registry).
- M-D1b complete (ETS scratchpad for `active_app: :stocksage`).

## Sequence

```
M-D2b + M-AppContract-Lite + M-D1b → M-D3a → M-D3b
```

M-D3a can run parallel to v0.15–v0.16. M-D3b can run parallel to v0.16.

## LiveViews (M-D3a)

```
/stocksage/                → StockSageLive.WorkspaceLive  dashboard + quick enqueue
/stocksage/analysis/:id    → StockSageLive.AnalysisLive   tabbed detail view
/stocksage/queue           → StockSageLive.QueueLive       live queue with PubSub
/stocksage/trends          → StockSageLive.TrendsLive      accuracy charts, leaderboard
```

Routes mounted in `allbert_assist_web` router via `App.Registry` (statically
configured, not dynamically injected at runtime). PubSub topics carry agent
progress events; LiveViews use `stream/3` for timeline rendering.

## Scope (M-D3b)

- Outcome resolver: local scheduled OTP worker fetches post-holding-period
  returns, generates LLM reflection, resolves `Outcome` record.
- Memory sync: resolved outcomes create `MemoryEntry` records → allbert
  memory namespace.
- Trends dashboard: alpha-aware accuracy, rating calibration, leaderboard.
- Analysis re-run from LiveView.
- Mobile-responsive layout.
- Error state handling and empty state UI.

## Canvas Integration (NOT in M-D3)

`StockSageWeb.Canvas.StockChart` and `StockSageWeb.Canvas.AnalysisCard`
register with the v0.17 canvas catalog only after v0.17 ships. That is
M-Canvas, a separate milestone.

## Non-Goals

- No canvas component registration (M-Canvas).
- No `canvas_ops` in agent responses (M-Canvas).
- No PostgreSQL for the local LiveView path.
- No Oban for queue workers; OTP/Jido workers + SQLite queue records.

## Definition Of Done (high level — detail added pre-implementation)

- M-D3a: Full analysis cycle from browser; live progress updates without page
  refresh; trends charts load; `active_app: :stocksage` is set in session
  scratchpad when user navigates to `/stocksage/`.
- M-D3b: All Python StockSage 0.0.2 user-facing features replicated; outcome
  resolver runs without a Python runtime if M-D2c native parity has passed;
  mobile-responsive layout passes manual review.
