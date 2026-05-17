# Agent Context Map

This is the optional, lazy-loaded routing map for coding agents. Use it when a
task touches released behavior and the active plan plus ADRs are not enough.
Do not load every section by default.

## How To Use This File

- Start with `AGENTS.md`, `DEVELOPMENT.md`, the roadmap, the active plan, and
  relevant ADRs.
- Read only the subsystem section below that matches the task.
- Use `CHANGELOG.md` for shipped-history context and regression clues.
- Treat active plans, ADRs, code, and tests as more authoritative than
  historical release summaries.
- Do not add AI-tool attribution, co-author trailers, or generated-by footers
  to commits, PR text, release notes, changelog entries, or generated docs.

## Subsystem To Docs Map

| Area | Start With | Released History |
| --- | --- | --- |
| Runtime, signals, agents, action runner | ADR 0001, ADR 0007, active plan | v0.01, v0.04, v0.06 |
| Security Central, permissions, trust, redaction | ADR 0006, ADR 0007, active plan | v0.05, v0.06 |
| Confirmations and approval resume | ADR 0008, active plan | v0.07 |
| Local execution, scripts, packages, external services | ADR 0009, ADR 0010, ADR 0011, ADR 0012, ADR 0013 | v0.08-v0.11 |
| Local identity, users, threads, conversation history | ADR 0014 | v0.12 |
| Scheduled jobs | ADR 0008, ADR 0012, ADR 0014 | v0.13 |
| Session scratchpad and active app context | ADR 0014 | v0.14 |
| App registration and surfaces | ADR 0015 | v0.15, v0.18 |
| Channels and external identity mapping | ADR 0016 | v0.16 |
| Plugins and plugin-contributed apps/actions/skills/channels | ADR 0017 | v0.17 |
| Intent candidates, active app routing, classifier hooks | ADR 0019 | v0.19 |
| StockSage plugin app and domain | ADR 0018, ADR 0017, ADR 0015 | v0.20 |
| Markdown memory review, promotion, index, retrieval | ADR 0014, ADR 0019 | v0.21 |
| Jido.Agent vs GenServer substrate (pragmatic rule) | ADR 0007, vision "Jido.Agent vs GenServer", v0.23 plan | v0.23 |
| Objectives, steps, events, advisory providers, world models | ADR 0021, v0.24 plan, research note | v0.24 |
| StockSage bridge, agents, LiveViews, canvas | Active StockSage milestone plan | v0.22, v0.25, v0.27, v0.29, v0.30 |
| Workspace shell, ephemeral UI, canvas | ADR 0015, active workspace plan | v0.26, v0.30 |
| Plugin/app generator | ADR 0017, ADR 0015, v0.31 plan | v0.31 |

## Version Map

- v0.01: first local assistant loop, signals, direct answer, markdown memory,
  traces, CLI and LiveView entrypoints.
- v0.03: Agent Skill compatibility/importability substrate.
- v0.04: runtime convergence and boundary actions.
- v0.05: Security Central vocabulary and enforcement baseline.
- v0.06: action-backed skill execution through registered actions.
- v0.07: durable confirmation workflow.
- v0.08: Level 1 local shell execution policy.
- v0.09: trusted skill script runner with resource gates.
- v0.10: confirmed external capability adapters, package installs, online
  skill search/import.
- v0.11: execution-aware intent, Approval Handoff, Resource Access Security
  Posture.
- v0.12: local workspace identity and SQLite conversation history.
- v0.13: scheduled jobs and supervised scheduler.
- v0.14: volatile session scratchpad and active app context.
- v0.15: minimal app registration contract.
- v0.16: Telegram/email channel substrate and explicit external identity
  mapping.
- v0.17: plugin contract and shipped source-tree channel plugins.
- v0.18: full app contract and validated surface DSL.
- v0.19: cross-surface intent candidates and active app ranking.
- v0.20: StockSage plugin app, local domain, import, actions, and skills.
- v0.21: memory review, correction, pruning, promotion, index, search, and
  memory intent candidates.
- v0.22: StockSage Python bridge and `RunAnalysis` confirmation flow. Released
  and tagged after audit closeout and post-implementation gap fixes.
- v0.23: planned Jido State-Machine Convergence for Confirmations.Store and
  Jobs.Scheduler.
- v0.24: planned Objective Runtime Foundation.

## Area Notes

### Runtime And Actions

Runtime-facing, effectful, security-relevant, or observable behavior should
enter through signals, internal agents/runtime routers, and registered Jido
actions. CLI tasks, LiveViews, jobs, and channels should not own domain
semantics directly. Use `AllbertAssist.Actions.Runner.run/3` for action
execution so lifecycle signals, runner metadata, permission decisions,
redaction, and traces stay consistent.

### Security And Resource Access

Security Central owns permission decisions. Skills, model output, app metadata,
plugin metadata, YAML declarations, and generated files never grant authority.
Resource grants are operation-scoped; a grant for one operation class must not
authorize another.

### Memory

Markdown memory is the long-term, inspectable source of truth. SQLite
conversation history is separate local workspace context and is not
auto-promoted. v0.21 added review, correction, archive, prune, promotion,
derived indexes/summaries, and metadata-only memory intent candidates.

### Plugins And Apps

Plugins are package/discovery contracts, not authority. They may contribute
apps, actions, skills, settings schema entries, channel descriptors, and
supervised children. They must not load arbitrary code from user folders, grant
trust, grant permissions, bypass confirmations, or execute package managers
during discovery.

### StockSage

StockSage is a shipped source-tree plugin app under `./plugins/stocksage`.
It uses `AllbertAssist.Repo` and `stocksage_*` tables. Do not create
`apps/stocksage`, `apps/stocksage_web`, or a separate `StockSage.Repo`.
Permission for local domain writes does not authorize financial API calls or
analysis execution.

### Workspace And Surfaces

Apps may have reviewed Phoenix LiveViews and routes, but web surfaces must be
declared through `AllbertAssist.App.SurfaceProvider` and validated by
`AllbertAssist.Surface`. Surface metadata is not authority and must not create
routes dynamically without an explicit plan.

### Jido.Agent vs. GenServer Substrate (v0.23)

Allbert uses both `Jido.Agent` and plain `GenServer` for state-bearing
components. The pragmatic rule (from v0.23 and the vision): use `Jido.Agent`
when state machines, documented lifecycle hooks (`on_before_cmd/2`,
`on_after_cmd/3`), Skill composition, or successor agents are plausibly
useful; use plain `GenServer` for stateful storage where Jido.Agent buys
nothing. Before v0.23, only `IntentAgent` is a Jido agent. v0.23 converts
`Confirmations.Store` and `Jobs.Scheduler`; v0.24 adds
`Objectives.Engine`. `Confirmations.Store` remains Allbert Home file-backed,
not SQLite-backed. `Jobs.Scheduler` remains SQLite-job-backed and keeps no
authoritative in-memory job queue. `Settings`, `Trace`, `Memory` storage IO,
`Session.Scratchpad`, `Memory.Compiler`, and `Memory.Promotion` stay plain
GenServers/modules. New modules document their substrate choice in the module
`@moduledoc`. Private Jido command modules inside these agents are not
registered Allbert capability actions and must not appear in intent candidates.

### Objectives And Advisory Providers (v0.24)

The objective runtime is the durable cross-turn substrate. `Objectives`
hold acceptance criteria and status; `Objective.Step` records hold
per-step work; `Objective.Event` records hold lifecycle history.
`Objectives.Engine` is a `Jido.Agent` implementing a seven-stage state
machine: receive → interpret intent → frame/resume objective → propose
and evaluate steps → authorize → execute → observe and advance.

Authority rule (ADR 0021): `objective_id` is not permission;
`active_app` on an objective is not permission; advisory provider
output (LLM proposers, world-model predictors, diffusion proposers,
market allocators, probabilistic critics) is never authority. Everything
effectful flows through `Actions.Runner.run/3` and Security Central.

Reserved vocabulary: capability inventory, capability gap, route,
acquisition option, world-model provider, diffusion proposer, market
allocator. Named in ADR 0021; not implemented in v0.24. Research note
at `docs/research/objective-runtime-research.md`.
