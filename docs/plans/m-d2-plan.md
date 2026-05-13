# Allbert D-Track M-D2: StockSage Domain, Analysis Engine, And Trading Agents

## Status

Planning. Full spec lives in `docs/plans/aiworkspace-plan.md` §4 (D2) and §11
(M-D2a, M-D2b, M-D2c milestones). This plan file will be expanded to
implementation-ready detail when M-AppContract-Lite completes.

## Purpose

M-D2 brings StockSage analysis into the Allbert umbrella in three phases:

- **M-D2a** — `stocksage` and `stocksage_web` umbrella apps scaffolded;
  SQLite-first domain records; `StockSage.App` implementing M-AppContract-Lite;
  StockSage skill pack; SQLite import task from existing Python `stocksage.db`.
- **M-D2b** — TradingAgents callable through a supervised Python bridge
  (ErlPort or JSON-over-stdio Port); `mix stocksage.analyze AAPL 2026-05-01`
  produces a real analysis and persists to SQLite.
- **M-D2c** — Replace Python bridge with native Jido AI agents for the full
  analysis pipeline. Bridge remains selectable via `--engine python`. Native
  becomes the default only after golden-fixture and batch parity checks pass.

## Hard Prerequisites

- M-AppContract-Lite complete (StockSage.App registers via the contract).
- M-D1a complete (string `user_id` on all domain records; no accounts FK).

## Sequence

```
M-AppContract-Lite → M-D2a → M-D2b → M-D2c
```

M-D2a–M-D2c run parallel to core track v0.12–v0.15.

## New Umbrella Apps

```
apps/stocksage/        OTP core — agents, actions, domain, trader_bridge
apps/stocksage_web/    Phoenix surface — added in M-D3, stub only in M-D2
```

## Domain Records (M-D2a)

All records carry string `user_id`. No foreign key to an accounts table.

```
StockSage.Domain.Analysis        canonical analysis by ticker/date/model
StockSage.Domain.AnalysisDetail  per-analyst sub-results
StockSage.Domain.Outcome         resolved outcome after holding period
StockSage.Domain.AnalysisQueue   user-facing request queue
StockSage.Domain.QueueRun        background run tracking
StockSage.Domain.MemoryEntry     lessons → allbert memory namespace
```

## Native Agent Topology Target (M-D2c)

```
StockSage.Analysis.Pod
├── OrchestratorAgent
├── MarketAnalystAgent
├── SentimentAnalystAgent
├── NewsAnalystAgent
├── FundamentalsAnalystAgent
├── BullResearcherAgent
├── BearResearcherAgent
├── TraderAgent
└── PortfolioManagerAgent
```

All agents use `Jido.AI.Agent` with a ReAct strategy. OTP/Jido workers plus
SQLite-backed queue records replace Oban as the background execution substrate
for the local path.

## Non-Goals

- No PostgreSQL dependency in the local path.
- No Oban as a hard dependency; OTP/Jido workers + SQLite queue records first.
- No StockSage LiveViews in M-D2 (those are M-D3).
- No native agents as the default until M-D2c golden-fixture parity gate.
- No cross-app FK to `AllbertAssist.Accounts.User`.

## Definition Of Done (high level — detail added pre-implementation)

- M-D2a: All StockSage domain records round-trip; existing Python `stocksage.db`
  imports cleanly; StockSage skills appear in `mix allbert.skills list`; no
  local PostgreSQL server required.
- M-D2b: `mix stocksage.analyze AAPL 2026-05-01` returns a decision, persists
  to SQLite, and is reachable via `mix allbert.ask --user local "analyze AAPL"`.
- M-D2c: Native analysis selectable with `--engine native`; 20-stock smoke
  batch and golden fixtures produce decisions matching the Python baseline
  within a documented variance band; native becomes the default.
