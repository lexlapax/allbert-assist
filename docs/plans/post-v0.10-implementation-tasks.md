# Post-v0.10 Implementation Tasks

**Starting point:** v0.10 is complete and tagged. This document is the
sequenced task list for everything that follows, covering both the core
v0.11–v0.17 track and the parallel D-track (StockSage / workspace apps).

Two tracks run in parallel. The core track cannot be blocked by D-track slips
**except for one hard gate**: v0.17 canvas work requires M-AppContract-Full to
complete first. Everything else is parallel and can slip independently.

---

## Phase 1 — Start Now (parallel)

Both tasks can begin at the same time. They share one coordination point: the
`AllbertAssist.Intent.Decision` struct shape. Define the struct in v0.11 first
(or coordinate closely), then M-D1a wires context into it.

### [ ] v0.11 — Execution-Aware Intent, Approval Handoff, Resource Access

Plan: `docs/plans/v0.11-plan.md`

Key deliverables:
- `AllbertAssist.Intent.Decision` struct with reserved fields: `user_id`,
  `thread_id`, `session_id`, `active_app` (no conversation history wiring yet)
- URI-backed resource access posture on risky decisions
- Approval Handoff plain-data contract
- CLI/REPL and web surfaces render channel-native approve/deny affordances

Exit: intent decisions are inspectable, risky capabilities produce posture
data, confirmation-needed prompts produce Approval Handoff.

### [ ] M-D1a — Multi-User Conversation History (parallel to v0.11)

Plan: `docs/plans/m-d1-plan.md` (M-D1a section)

Key deliverables:
- `AllbertAssist.Memory.Thread` and `AllbertAssist.Memory.Message` Ecto
  schemas + SQLite migrations
- `Runtime.submit_user_input/1` accepts and propagates `user_id`, `thread_id`,
  `session_id`
- Intent agent reads last N messages from thread as context prefix
- Mix tasks: `--user`, `--thread`, `--new-thread` flags; `mix allbert.threads`
- `AgentLive` thread list sidebar

Exit: `mix allbert.ask --user alice "hello"` creates a thread; a follow-up
question reads context correctly; legacy single-user calls unchanged.

---

## Phase 2 — After Phase 1 Is Underway (parallel)

Start these once Phase 1 is in flight. v0.12 waits for v0.11 to ship;
M-D1b and M-AppContract-Lite can start as soon as M-D1a's `user_id` exists
in the runtime.

### [ ] v0.12 — Scheduled Jobs (after v0.11 ships)

Plan: `docs/plans/v0.12-plan.md`

Key deliverables:
- Cron-like jobs emitting signals into the same runtime
- Jobs carry string `user_id`, optional `thread_id` and `app_id` from the
  originating request (no accounts schema)
- Risky job actions pause for confirmation; no invisible background execution

Exit: jobs are stored, listed, paused, and resumed; low-risk jobs run; risky
job actions wait for approval.

### [ ] M-D1b — ETS Session Scratchpad (after M-D1a, parallel to v0.12)

Plan: `docs/plans/m-d1-plan.md` (M-D1b section)

Key deliverables:
- `AllbertAssist.Session.Scratchpad` ETS table started in supervision tree
- Key: `{user_id, session_id}`; TTL expiry via `:timer`
- `active_app` atom stored here for app-scoped routing (v0.15 consumes it)
- `AgentLive` stores `session_id`; runtime reads scratchpad on each turn

Exit: two concurrent sessions for the same user get isolated scratchpad
entries; stale entries expire; no state survives restart.

### [ ] M-AppContract-Lite — Minimal App Registration (after M-D1a, parallel to v0.12–v0.13)

Plan: `docs/plans/m-appcontract-lite-plan.md`

Key deliverables:
- `AllbertAssist.App` behaviour: `app_id/0`, `display_name/0`, `version/0`,
  `validate/1`, `child_spec/1`, `actions/0`, `skill_paths/0`, `surfaces/0`
- `AllbertAssist.App.Registry` with `register/2`, `lookup/1`,
  `registered_apps/0`, `registered_surfaces/0`
- `AllbertAssist.App.Supervisor` (DynamicSupervisor) in supervision tree
- `AllbertAssist.Actions.Registry` gains optional `app_id:` tag
- Workspace shell nav renders registered app surfaces

Exit: a minimal test app registers one action, one skill path, and one nav
surface; existing Allbert runtime is unchanged.

> **HARD GATE:** M-D2a cannot start until M-AppContract-Lite is done.

---

## Phase 3 — After Phase 2 Is Underway (parallel)

### [ ] v0.13 — Additional Channels (after v0.12)

Plan: `docs/plans/v0.13-plan.md`

Key deliverables:
- At least one channel adapter (Telegram-style, email, or SMS) translating
  external messages into Allbert signals
- External identity → local string `user_id` mapped via Settings Central
- Channel traces include both external identity and resolved `user_id`

Exit: one adapter can submit messages through runtime; credentials in Settings
Central; no embedded agent logic in the adapter.

### [ ] M-D2a — StockSage Umbrella App + Domain (after M-AppContract-Lite)

Plan: `docs/plans/m-d2-plan.md` (M-D2a section)

Key deliverables:
- `stocksage` and `stocksage_web` umbrella apps scaffolded
- `StockSage.App` implementing M-AppContract-Lite
- SQLite-backed domain records: `Analysis`, `AnalysisDetail`, `Outcome`,
  `AnalysisQueue`, `QueueRun`, `MemoryEntry` — all with string `user_id`
- StockSage skill pack: `run-analysis`, `get-trends`, `queue-analysis` SKILL.md
- `mix stocksage.import_sqlite /path/to/stocksage.db` imports Python data
- No local PostgreSQL required

Exit: domain records round-trip; Python `stocksage.db` imports cleanly;
StockSage skills appear in `mix allbert.skills list`.

---

## Phase 4 — After Phase 3 Is Underway (parallel)

### [ ] v0.14 — Memory Review And Retrieval (after v0.13)

Plan: `docs/plans/v0.14-plan.md`

Key deliverables:
- Operator review, correction, promotion, and pruning of markdown memory
- Summaries and compiled views derived from markdown sources
- SQLite conversation history (from M-D1a) treated as a separate tier;
  no automatic promotion of thread turns to markdown entries

Exit: operators can review and prune markdown memory; derived artifacts are
rebuildable; thread history is not auto-promoted.

### [ ] M-D2b — Python Bridge (after M-D2a, parallel to v0.14–v0.15)

Plan: `docs/plans/m-d2-plan.md` (M-D2b section)

Key deliverables:
- `StockSage.TraderBridge` supervised bridge (ErlPort or JSON-over-stdio Port)
- `priv/python/bridge.py` wrapping TradingAgents
- `StockSage.Actions.RunAnalysis` calling the bridge
- `mix stocksage.analyze AAPL 2026-05-01` returns a decision, persists to DB
- IntentAgent routes "analyze AAPL" → `run-analysis` skill → `RunAnalysis`

Exit: `mix stocksage.analyze` returns a decision; result is reachable via
`mix allbert.ask --user local "analyze AAPL for last week"`.

---

## Phase 5 — After Phase 4 Is Underway (parallel)

### [ ] v0.15 — Cross-Surface Intent Enrichment (after v0.14)

Plan: `docs/plans/v0.15-plan.md`

Key deliverables:
- Hybrid deterministic + model-assisted intent engine
- `active_app` from ETS scratchpad scopes action candidate ranking when
  M-AppContract-Lite is present
- App-registered skill paths participate in candidate ranking
- Eval fixtures for activation, non-activation, permission, channel, refusal

Exit: intent can explain skill/action/job selection; model-assisted
classification is bounded and testable; app-scoped routing works when
`active_app` is set.

### [ ] M-D2c — Native Jido Trading Agents (after M-D2b, parallel to v0.15–v0.16)

Plan: `docs/plans/m-d2-plan.md` (M-D2c section)

Key deliverables:
- 8 Jido.AI.Agent modules: Orchestrator, MarketAnalyst, Sentiment, News,
  Fundamentals, BullResearcher, BearResearcher, Trader, PortfolioManager
- Jido Pod topology for the analysis workflow
- OTP/Jido workers + SQLite queue records for background execution
- `--engine native` flag on `mix stocksage.analyze`; Python bridge remains
  available via `--engine python`
- 20-stock smoke batch + golden fixtures within documented variance band

Exit: native analysis matches Python baseline; native becomes the default.

### [ ] M-D3a — StockSage LiveViews (after M-D2b + M-AppContract-Lite + M-D1b, parallel to v0.15–v0.16)

Plan: `docs/plans/m-d3-plan.md` (M-D3a section)

Key deliverables:
- `WorkspaceLive`, `AnalysisLive`, `QueueLive`, `TrendsLive`
- Routes mounted in `allbert_assist_web` via registry (statically configured)
- Real-time analysis progress via PubSub + `stream/3`
- `active_app: :stocksage` set in scratchpad when user navigates to `/stocksage/`

Exit: full analysis cycle from browser; live progress updates without page
refresh; trends charts load.

---

## Phase 6 — After Phase 5 Is Underway (parallel)

### [ ] v0.16 — Security Hardening And Evals (after v0.15)

Plan: `docs/plans/v0.16-plan.md`

Key deliverables:
- Security eval fixtures: prompt injection, SSRF, command bypass, credential
  leakage, cross-session data access, supply chain
- D-track evals (conditional on what has landed):
  - Cross-user/thread leakage (needs M-D1a)
  - App-scoped action routing (needs M-AppContract-Lite)
  - Python bridge protocol/path/crash security (needs M-D2b)
  - Financial workflow authorization (needs M-D2b)
  - App registration security (needs M-AppContract-Full if landed)
- Operator-visible security review workflows

Exit: evals cover real failure modes; D-track fixtures present and passing
or explicitly marked pending with conditions.

### [ ] M-AppContract-Full — Full App Contract + Surface DSL (parallel to v0.15–v0.16)

Plan: `docs/plans/m-appcontract-full-plan.md`

Key deliverables:
- `AllbertAssist.App` behaviour: full five-layer spec
- `AllbertAssist.App.Registry` updated with signal subscriptions, settings
  validation, memory namespace registration
- `AllbertAssist.App.SurfaceProvider` behaviour
- `AllbertAssist.Surface` component DSL with catalog validation
- `AllbertAssist.Surface.Encoder.to_a2ui/1` (optional bridge)
- `mix allbert.validate_app MyApp` mix task
- `StockSage.App` fully implements all five layers
- ADR 0015 transitions to Accepted
- `docs/how-to-create-an-allbert-app.md` developer guide

Exit: `mix allbert.validate_app StockSage.App` passes; ADR 0015 is Accepted.

> **HARD GATE:** v0.17 cannot start until BOTH v0.16 AND M-AppContract-Full
> are complete.

### [ ] M-D3b — StockSage Polish, Outcomes, Trends (after M-D3a, parallel to v0.16)

Plan: `docs/plans/m-d3-plan.md` (M-D3b section)

Key deliverables:
- Outcome resolver OTP worker: fetches returns, generates LLM reflection
- Memory sync: resolved outcomes → allbert memory entries
- Trends dashboard: alpha-aware accuracy, rating calibration, leaderboard
- Analysis re-run from LiveView
- Mobile-responsive layout; error states; empty states

Exit: all Python StockSage 0.0.2 user-facing features replicated in Elixir.

---

## Phase 7 — Double Gate (v0.16 AND M-AppContract-Full must both be done)

### [ ] v0.17 — Agentic Workspace Surface And Ephemeral UI Substrate

Plan: `docs/plans/v0.17-plan.md`

Key deliverables:
- LiveView workspace shell consuming M-AppContract-Full's app registry and
  `AllbertAssist.Surface` DSL
- Canvas persistence semantics vs ephemeral surface scoping and cleanup
- Signal timeline: conversation, agent events, PubSub → LiveView stream
- Approval inspector, trace inspector, memory review surface, job state
- Workspace shell nav populated from `App.Registry.registered_surfaces/0`
- Canvas component catalog validated against `AllbertAssist.Surface`
- Security: generated surfaces cannot invent actions, permissions, or URLs

Exit: signal-driven workspace shell exists; canvas and ephemeral UI semantics
are distinct; registered apps populate navigation; model output is catalog-bound.

---

## Phase 8 — After Phase 7

### [ ] M-Canvas — StockSage Canvas Integration (after v0.17 + M-D3b)

Plan: `docs/plans/m-canvas-plan.md`

Key deliverables:
- `StockSageWeb.Canvas.StockChart` and `StockSageWeb.Canvas.AnalysisCard`
  components registered with the v0.17 canvas catalog
- `StockSage.App.canvas_components/0` callback
- `canvas_ops` in agent responses for analysis results
- Dashboard tiles for recent analyses

Exit: `mix allbert.ask "analyze AAPL"` pushes a `stock_chart` tile to canvas;
tile survives page reload.

### [ ] v0.18 — Allbert App Generator (after v0.17 + M-D3b)

Plan: stub in roadmap. Full plan written when M-D3b is done.

Key deliverables:
- `mix allbert.gen.app MyApp` scaffolds all five contract layers
- `mix allbert.validate_app MyApp` passes on first run
- Optional: `mix allbert.publish_skills`

---

## Dependency Summary

```
v0.11 ─────────────────────────────────────────────────────── v0.12 ── v0.13 ── v0.14 ── v0.15 ── v0.16 ──┐
                                                                                                            ├── v0.17 ── v0.18
M-D1a ── M-D1b ┐                                                                                            │
               ├── M-AppContract-Lite ── M-D2a ── M-D2b ── M-D2c                                           │
               │                              └── M-D3a ── M-D3b ──────────────────────────────────────────┤
               │                                                                                            │
               └──────────────────── M-AppContract-Full ────────────────────────────────────────────────────┘
                                     (parallel to v0.15-v0.16)

After v0.17: M-Canvas
```

**Hard gates:**
1. `M-AppContract-Lite` must finish before `M-D2a` starts
2. `v0.16` AND `M-AppContract-Full` must both finish before `v0.17` starts

**Everything else** runs in parallel. Core track milestones (v0.11–v0.16)
do not wait for D-track milestones. D-track milestones may slip without
blocking the core track.
