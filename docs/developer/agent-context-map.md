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
| Security Central, permissions, trust, redaction, eval harness | ADR 0006, ADR 0007, ADR 0012, `docs/plans/v0.28-plan.md`, `docs/plans/v0.28-request-flow.md` | v0.05, v0.06, v0.11, v0.28 |
| Confirmations and approval resume | ADR 0008, active plan | v0.07 |
| Local execution, scripts, packages, external services | ADR 0009, ADR 0010, ADR 0011, ADR 0012, ADR 0013 | v0.08-v0.11 |
| Local identity, users, threads, conversation history | ADR 0014 | v0.12 |
| Scheduled jobs | ADR 0008, ADR 0012, ADR 0014 | v0.13 |
| Session scratchpad and active app context | ADR 0014 | v0.14 |
| App registration, surfaces, app-scoped routing | ADR 0015, `docs/plans/v0.27-plan.md`, `docs/plans/v0.28-plan.md` | v0.15, v0.18, v0.27, v0.28 |
| Channels and external identity mapping | ADR 0016 | v0.16 |
| Plugins and plugin-contributed apps/actions/skills/channels | ADR 0017 | v0.17 |
| Intent candidates, active app routing, classifier hooks | ADR 0019 | v0.19 |
| StockSage plugin app, domain, outcomes, reflections, reruns | ADR 0018, ADR 0017, ADR 0015, `docs/plans/v0.29-plan.md`, `docs/plans/v0.29-request-flow.md` | v0.20, v0.27, v0.29 |
| Markdown memory review, promotion, index, retrieval, app memory sync | ADR 0014, ADR 0019, `docs/plans/v0.21-plan.md`, `docs/plans/v0.29-plan.md` | v0.21, v0.29 |
| Jido.Agent vs GenServer substrate (pragmatic rule) | ADR 0007, vision "Jido.Agent vs GenServer", v0.23 plan | v0.23 |
| Objectives, steps, events, advisory providers, world models | ADR 0021, ADR 0019, v0.24 plan/request-flow, research note | v0.24 |
| StockSage Python bridge | `docs/plans/v0.22-plan.md`, ADR 0020 | v0.22 |
| StockSage native financial specialist agents (10 + coordinator) | `docs/plans/v0.25-plan.md`, `docs/plans/v0.25-request-flow.md`, ADR 0022 | v0.25 |
| StockSage LiveViews and app-flow UX | `docs/plans/v0.27-plan.md`, `docs/plans/v0.27-request-flow.md`, ADR 0015, ADR 0018 | v0.27 |
| StockSage security posture and adversarial evals | `docs/plans/v0.28-plan.md`, `docs/plans/v0.28-request-flow.md`, ADR 0015, ADR 0023 | v0.28 |
| StockSage app memory, outcomes, reflection sync, reruns | `docs/plans/v0.29-plan.md`, `docs/plans/v0.29-request-flow.md`, ADR 0015, ADR 0018, ADR 0022 | v0.29 |
| Workspace shell, canvas, ephemeral UI substrate | ADR 0015 (catalog), ADR 0023 (workspace substrate), `docs/plans/v0.26-plan.md`, `docs/plans/v0.26-request-flow.md` | v0.26 |
| StockSage canvas integration, workspace plugin contributions | `docs/plans/v0.30-plan.md`, `docs/plans/v0.30-request-flow.md`, ADR 0015, ADR 0023 | v0.30 |
| Runtime/UI-substrate consolidation, action DSL, settings fragments, unified catalog/registry | ADR 0026, ADR 0027, ADR 0028, ADR 0029, ADR 0030, ADR 0031, `docs/plans/v0.31-plan.md`, `docs/developer/runtime-boundary-map.md` | v0.31 |
| Workspace-only plugin UI, panel surfaces, named zones, workspace Settings Central | ADR 0024, ADR 0015, ADR 0023, `docs/plans/v0.32-plan.md` | v0.32 |
| User theming and layout overrides | ADR 0025, ADR 0024, `docs/plans/v0.33-plan.md` | v0.33 |
| Dynamic plugin/app generation and sandboxed module loading | ADR 0032, ADR 0033, ADR 0009, ADR 0021, `docs/plans/v0.34-plan.md` | v0.34 |
| Plugin/app generator | ADR 0017, ADR 0015, ADR 0024, ADR 0025, ADR 0030, ADR 0031, ADR 0032, `docs/plans/v0.35-plan.md` | v0.35 |

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
- v0.23: Jido State-Machine Convergence for Confirmations.Store and
  Jobs.Scheduler using `AllbertAssist.JidoBacked`.
- v0.24: Objective Runtime Foundation: durable objectives,
  objective steps/events, canonical runtime turn signal aliases,
  objective signals, SignalBridge, and objective intent candidates.
- v0.25: Native financial specialist agents for StockSage: 9 reusable
  supervised LLM-capable `Jido.Agent` delegate specialists whose execute
  command calls Jido.AI (analysts, bull/bear theses, 3 risk debaters,
  decision synthesizer) + 1 deterministic Jido.Agent quality gate + 1 JidoBacked
  `StockSage.Agents.NativeCoordinator` orchestrator. Multi-round
  bull/bear/risk debate runs inside the plugin-owned coordinator graph
  while recording durable v0.24 objective steps. 5 tiered evidence actions
  (`StockSage.Actions.Evidence.*`) with new `:stocksage_evidence_fetch`
  permission class. `--engine both` parallel parity runs with 5-point
  rating-scale agreement metric. Per-agent model profiles drive Jido.AI
  generation when `stocksage.native_llm_enabled` is true. Prompt files are
  Allbert-authored; verbatim TradingAgents prompt adaptation is deferred
  until an explicit license audit. New `mix allbert.delegate
  <agent_id>` Mix task in Allbert core proves cross-app callability.
  No one-for-one Python graph clone. No automatic native → Python
  fallback, and no persistent Python/parity engine default.
- v0.26: Agentic Workspace Surface And Ephemeral UI Substrate (implemented
  2026-05-18; release tag pending operator acceptance). The
  `/agent` LiveView becomes a fully-dynamic workspace shell rendered
  by walking a Surface tree composed of regions, tiles, and
  ephemeral surfaces. Per-thread Canvas (persistent tiles bound to
  v0.12 thread; survives refresh + restart) and per-thread Ephemeral
  Surfaces (task-scoped overlays, shared across tabs of same thread,
  GC'd on thread close). Hybrid SQLite-metadata + YAML-body
  persistence. Catalog expands from 12 → 42 components (10 workspace
  structural + 12 Allbert-domain + 4 Allbert-app cards + 4 reserved
  StockSage cards rendered as stubs + 12 v0.18 carryover). Strict +
  HMAC-signed `FragmentEnvelope` emission via
  `allbert.workspace.fragment.**` SignalBus topic; receiver
  validates envelope shape, signature, catalog component, emitter
  allow-list, per-emitter rate limit, payload size. Multi-tab sync
  via PubSub. WCAG 2.1 AA accessibility (keyboard nav + ARIA + focus
  traps + skip-to-content). Dark mode + theme toggle. Mobile
  responsive (two-pane above 768px, single-pane with tab toggle
  below). Offline text/markdown tile editing via service worker +
  browser-side Yjs + IndexedDB with bounded reconnect sync +
  conflict banner UX.
  Internal `AllbertAssist.Workspace.AGUI.Bridge` translates curated
  Allbert signals to AG-UI event shape for test-only semantic
  mapping (NOT exposed over HTTP). 14 new `workspace.*` settings.
  New `:workspace_canvas_write` permission class. 9 new
  `allbert.workspace.**` signal topics. `## Workspace` trace
  section + inline `### Workspace` subsection. `mix
  allbert.workspace canvas|ephemeral|inspect|rotate-signing-secret`
  Mix tasks. Per ADR 0023.
- v0.27: App Surface Contract - StockSage LiveViews. StockSage now has
  plugin-owned `StockSageWeb.WorkspaceLive`, `AnalysisLive`, `QueueLive`, and
  `TrendsLive` mounted by the host router at `/stocksage/*` and declared
  through `StockSage.App.surfaces/0`. It ships real StockSage-owned renderers
  for `:analysis_card`, `:agent_report_card`, `:parity_card`, and
  `:debate_round_card`, `RunAnalysis` validated `surface_nodes`, objective and
  confirmation state on analysis pages, PubSub progress streaming, and an inert
  `StockSage.App.memory_namespace/0` declaration with `writable: false`.
  v0.27 does not write markdown memory and does not emit durable `/agent`
  canvas tiles; those contracts remain v0.29 and v0.30 respectively.
- v0.28: Security Hardening And Evals. This is the security routing anchor
  after v0.26 workspace surfaces and v0.27 real StockSage app surfaces. It
  adds the shared security eval harness under `apps/allbert_assist/test/security`,
  adversarial fixtures, Resource Access trace assertions, app-scoped action
  routing coverage, disabled-plugin and registry-boundary coverage, surface
  catalog injection coverage, workspace fragment/canvas substrate coverage,
  objective and advisory-provider coverage, bridge/native StockSage coverage,
  namespace claim/isolation coverage before memory writes, and operator-facing
  security review/status tasks. Pre-tag hardening makes app-owned actions fail
  closed when `active_app` is missing, neutral, or wrong; jobs and objective
  execution propagate explicit active-app context instead of relying on
  `app_id` as authority.
- v0.29: App Memory + Outcomes Contract - StockSage Polish. StockSage now has
  outcome resolution through registered actions, due-outcome resolution,
  trend/calibration summaries, deterministic local reflection generation,
  explicit confirmation-gated lesson sync, app-memory metadata on
  `Memory.Entry`, idempotent namespaced memory upsert behind
  `sync_app_lesson`, no-auto-promotion tests, source-analysis-aware reruns,
  and polished app-flow UX for run context, empty/error states, and mobile-safe
  StockSage surfaces. v0.29 consumes the namespace declared in v0.27 and
  audited in v0.28; it still does not emit durable `/agent` canvas tiles.
- v0.30: App Canvas Contract - StockSage Canvas Integration. Released and
  tagged as `v0.30.0` after operator manual verification. `/agent` now
  renders durable StockSage canvas tiles with the v0.27
  `StockSageWeb.Components.Cards` renderers instead of v0.26 stubs.
  `RunAnalysis` lifecycle signals flow through
  `AllbertAssist.Workspace.Emitters.stocksage_signal/2`, signed
  `Workspace.Fragment.Envelope` validation, and the existing
  `workspace_canvas_tiles` + YAML body store. v0.30 adds no `:stock_chart`
  atom, no migration, no new StockSage domain behavior, and no private
  canvas-write path.
- v0.31 (planned): Runtime And UI-Substrate Consolidation. Consolidates the
  action DSL, typed runtime responses, shared paths/redaction/audit/persistence
  facades, unified Surface catalog/renderer path, unified extension registry,
  and settings fragments. Behavior-preserving: no route removals, theming,
  dynamic code, generator, domain behavior, or migrations. M3 adds
  `AllbertAssist.Runtime.Paths` and `AllbertAssist.Runtime.Redactor`; M4 adds
  `AllbertAssist.Runtime.Audit`, `AllbertAssist.Runtime.Persistence`, and
  `AllbertAssist.Runtime.Trace`; M5 adds `AllbertAssist.Action` and
  module-owned capability metadata for registered actions; M6 adds
  `AllbertAssist.Runtime.Response` for shared Runtime/Runner/objective response
  normalization. Per ADR 0026-0031.
- v0.32 (planned): Workspace-Only App UI And Settings Central. Makes
  `/workspace` the operator home; removes `/agent`, `/settings`, and
  `/stocksage/*` without compatibility redirects; adds `:panel` surfaces into
  host-owned zones (`:nav_apps`, `:context_rail`, `:canvas_panels`,
  `:utility_drawer`, `:ephemeral`); moves Settings Central into the workspace
  utility drawer; moves StockSage dashboard/recent/queue/trends into workspace
  panels; and migrates CoreApp domain cards to the same panel-zone path. Per
  ADR 0024. No new domain behavior, theming system, dynamic routing, or
  model-generated UI.
- v0.33 (planned): User Theming And Layout Overrides. Adds Allbert Home theme
  roots, token YAML, opt-in sanitized CSS snippets, validated workspace layout
  YAML, Settings Central keys, and CSP regression coverage for `/workspace`.
  Per ADR 0025.
- v0.34 (planned): Dynamic Plugin/App Generation And Sandboxed Module Loading.
  Generates inert local plugin/app drafts under `<ALLBERT_HOME>/plugins`,
  compiles and tries them only in an out-of-node sandbox, reports redacted
  diagnostics, and never loads generated modules into the core node. Per ADR
  0032 and ADR 0033.
- v0.35 (planned): Allbert Plugin And App Generator. Scaffolds the proven
  plugin/app shape, now including post-v0.31 action/settings/catalog shapes,
  panel surfaces, named zones, workspace settings hooks, the
  `/apps/<app_id>` route convention for rare pages, memory/action/objective/
  canvas stubs, v0.33 theming docs, and v0.34 dynamic-draft review notes.

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

For security work after v0.28, start with `docs/plans/v0.28-plan.md`,
`docs/plans/v0.28-request-flow.md`, and the eval modules under
`apps/allbert_assist/test/security/`. v0.28 hardened the app-scope boundary:
app-owned actions require explicit matching `active_app`, missing or neutral
scope fails closed, and non-interactive jobs/objectives must propagate trusted
active-app context before reaching `Actions.Runner.run/3`.

The `to_a2ui` redaction eval is a stub tripwire until protocol emission is
implemented after v0.35; do not treat it as full redaction coverage. Advisory
or proposer-origin memory writes must be stamped centrally by the objective or
memory-sync boundary, not by scattered callers.

### Memory

Markdown memory is the long-term, inspectable source of truth. SQLite
conversation history is separate local workspace context and is not
auto-promoted. v0.21 added review, correction, archive, prune, promotion,
derived indexes/summaries, and metadata-only memory intent candidates.

v0.29 adds explicit app-memory sync for StockSage without changing the
no-auto-promotion rule. Namespaced app-memory writes go through the registered
`sync_app_lesson` action, durable confirmation, and `Memory.upsert_app_entry/1`.
`Memory.Entry` carries app namespace metadata and an idempotency key so markdown
render/parse, filters, and review flows preserve app ownership. Completing an
analysis, resolving an outcome, or generating a reflection must not write memory
unless the operator explicitly approves the sync.

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

For StockSage surface work, read `docs/plans/v0.27-plan.md` and
`docs/plans/v0.27-request-flow.md` first. v0.27 owns `/stocksage/*`
LiveViews, real StockSage card renderers, validated `RunAnalysis`
`surface_nodes`, progress streaming, and the inert memory namespace
declaration. It does not write markdown memory and does not emit durable
workspace canvas tiles.

For StockSage security work, read v0.28 before editing runtime boundaries.
v0.28 added app-scope, registry, surface/catalog, namespace, Resource Access,
bridge/native, objective, and workspace-fragment evals around the StockSage
surface. The security posture assumes StockSage actions run only with explicit
`active_app: :stocksage` and normal confirmation/resource checks.

For StockSage memory/outcomes/rerun work, read `docs/plans/v0.29-plan.md`
and `docs/plans/v0.29-request-flow.md`. v0.29 owns outcome resolution,
trend calibration, deterministic reflections, explicit app-memory lesson sync,
source-analysis-aware reruns, and app-flow polish. It consumes the namespace
declared in v0.27 and audited in v0.28.

v0.25 native financial agents are plugin-owned but runtime-callable through
the shared objective delegate-agent substrate. Read
`docs/plans/v0.25-plan.md`, `docs/plans/v0.25-request-flow.md`, ADR 0020, ADR
0021, and ADR 0022 before touching them. The native agents should adapt the
TradingAgents baseline's role intent, fixtures, and result fields, not clone
every Python role/class one for one. v0.25 prompt/control files are
Allbert-authored; verbatim upstream prompt adaptation requires a future
explicit license-audit milestone.
`plugins/stocksage/priv/python/bridge.py` contains the bridge protocol and
final-state field list, not the role prompts; prompt inventory belongs under
`plugins/stocksage/priv/prompts/native_agents/`.

Native financial agents register 12 stable ids in
`AllbertAssist.Objectives.AgentRegistry` at app boot (per ADR 0022
Amendment A1):

- `stocksage.market_context` — Jido.AI; tool: FetchMarketData
- `stocksage.news_sentiment` — Jido.AI; tools: FetchNews, FetchSentiment
- `stocksage.fundamentals` — Jido.AI; tools: FetchMarketData, FetchFundamentals, FetchFinancials
- `stocksage.bull_thesis` — Jido.AI; multi-round capable
- `stocksage.bear_thesis` — Jido.AI; multi-round capable
- `stocksage.risk_aggressive` — Jido.AI; multi-round capable; slow-profile default
- `stocksage.risk_conservative` — Jido.AI; multi-round capable; slow-profile default
- `stocksage.risk_neutral` — Jido.AI; multi-round capable; slow-profile default
- `stocksage.research_manager` — Jido.AI; preliminary research decision; slow-profile default
- `stocksage.trader_plan` — Jido.AI; bounded advisory plan; slow-profile default
- `stocksage.decision_synthesizer` — Jido.AI; slow-profile default
- `stocksage.quality_gate` — plain Jido.Agent (deterministic; no LLM)

Plus one supervised JidoBacked orchestrator NOT registered in
AgentRegistry: `StockSage.Agents.NativeCoordinator` (per ADR 0022 A3).
The coordinator owns per-analysis projection, multi-round dispatch
order, and parity-run composition; it is called from
`StockSage.Actions.RunAnalysis` via `JidoBacked.dispatch/4`.

All agents return bounded advisory report packets per ADR 0022 only.
Market data, news, fundamentals, persistence, confirmations, settings,
traces, and final analysis writes still flow through registered
actions, `Actions.Runner.run/3`, Security Central, and Resource
Access Security Posture. The 5 tiered evidence actions live under
`StockSage.Actions.Evidence.*` and are gated by the new
`:stocksage_evidence_fetch` permission class (per ADR 0022 A4).

Multi-round debate (bull/bear/risk) is implemented inside the
plugin-owned native coordinator graph. Each specialist turn still
creates one `objective_steps` row of `kind: :delegate_agent` with
round metadata (per ADR 0022 A2). Operators inspect rounds via
`mix allbert.objectives show <id>`.

Engine choice is request-scoped. Absent engine means native;
`--engine python` and `--engine both` are explicit
comparison/reference modes, not Settings Central defaults.
`--engine both` runs native + Python concurrently; persists ONE
analysis row with both engines' fields populated + parity_diff JSON
(per ADR 0022 A5, A6). Parity metric: 5-point rating-scale agreement
(exact 1.0 / adjacent 0.5 / distant 0.0) + bounded confidence delta.

Cross-app callability: `mix allbert.delegate <agent_id>` Mix task lives
in Allbert core (not StockSage) and proves any registered specialist
agent is callable from outside StockSage via the v0.24 DelegateAgent
registered action + AgentRegistry (per ADR 0022 A7).

### Workspace And Surfaces

Apps may have reviewed Phoenix LiveViews and routes, but web surfaces must be
declared through `AllbertAssist.App.SurfaceProvider` and validated by
`AllbertAssist.Surface`. Surface metadata is not authority and must not create
routes dynamically without an explicit plan.

v0.28 is the security reference for this substrate: catalog bypass, component
injection, fragment replay/tampering, emitter allow-list, app-scope routing,
and workspace/canvas hard-disable behavior all have named eval coverage. v0.30
wires v0.27-proven StockSage components into durable workspace canvas tiles
through the v0.26/v0.28-audited mechanism; future app canvas work should reuse
that same signed Fragment path unless a new ADR changes the substrate.

v0.26 expands the Surface DSL substrate from a single chat-only `/agent`
LiveView to the shipped **agentic workspace shell**:

- The workspace shell IS itself a Surface tree (per ADR 0023 §2 + the
  v0.26 design choice). `CoreApp.surfaces/0` declares the workspace
  tree at boot; the web renderer walks it and dispatches each node's
  `:component` atom to a LiveComponent module through
  `AllbertAssistWeb.Workspace.Renderer`. M7 moves this dispatch table
  into the unified `AllbertAssist.Surface.Catalog`. There is NO hardcoded
  HEEx layout for regions.
- Per-thread Canvas (persistent tiles) lives in SQLite metadata +
  YAML body under `<ALLBERT_HOME>/workspace/canvas/<user_id>/<thread_id>/`.
  Per-thread Ephemeral Surfaces live in SQLite + YAML under
  `<ALLBERT_HOME>/workspace/ephemeral/<user_id>/<thread_id>/`. Both
  are shared across browser tabs viewing the same thread via the
  `SignalBridge.workspace_topic_for/2` PubSub topic
  `workspace:<user_id>:<thread_id>`.
- Runtime Fragment emission is signal-topic-driven: any in-BEAM
  module publishes a HMAC-signed `%Workspace.Fragment.Envelope{}` to
  `allbert.workspace.fragment.**`; `AllbertAssistWeb.SignalBridge`
  (extends v0.24) validates strictly (envelope shape + signature +
  catalog component + emitter allow-list + per-emitter rate limit +
  payload size) and forwards valid envelopes to the per-user
  `SignalBridge.topic_for/1` PubSub topic `objectives:<user_id>`.
  Invalid envelopes drop with bounded log +
  `allbert.workspace.fragment.dropped` signal.
- 42-component catalog (per ADR 0015 v0.26 amendment): 12 v0.18
  carryover + 10 workspace structural + 12 Allbert-domain + 4
  Allbert-app cards + 4 reserved StockSage cards. v0.27 ships real
  StockSage-owned app-surface renderers for those cards under `/stocksage/*`;
  v0.30 wires those same renderers into durable `/agent` canvas tiles without
  adding a new `:stock_chart` atom.
- 14 new `workspace.*` settings (theme, offline, accessibility,
  fixed read-only mobile breakpoint, fragment rate limits, etc.). New
  `:workspace_canvas_write` permission class.
- UX qualities are first-class in v0.26: dark mode, high contrast,
  reduced motion, structural accessibility coverage, mobile responsive
  layout, and offline text/markdown editing via browser-side Yjs +
  IndexedDB with bounded reconnect sync + conflict-banner UX. v0.26
  does not add a server-side Rust NIF or server-side CRDT interpreter;
  manual axe/screen-reader validation remains the release gate.
- Internal `AllbertAssist.Workspace.AGUI.Bridge` translates curated
  Allbert signals to AG-UI event shape for test-only semantic
  mapping; NOT exposed over HTTP. Public AG-UI / A2UI / MCP Apps
  interop is post-v0.35 (per Future Features UI Protocol
  Interop).

In v0.26, sibling routes (`/objectives/:id`, `/jobs`, `/settings`) remain
top-level for deep-linking. The workspace can render catalog-backed summary
tiles for those domains, but it does not replace the sibling routes in v0.26.
v0.32 supersedes this route shape for operator UI: Settings Central moves into
`/workspace`, and plugin workspace regions graduate as panels. Plugins MAY
emit Fragments via the SignalBus topic (existing v0.26 emission path).

### Jido.Agent vs. GenServer Substrate (v0.23)

Allbert uses both `Jido.Agent` and plain `GenServer` for state-bearing
components. The pragmatic rule (from v0.23 and the vision): use `Jido.Agent`
when state machines, documented lifecycle hooks (`on_before_cmd/2`,
`on_after_cmd/3`), Skill composition, or successor agents are plausibly
useful; use plain `GenServer` for stateful storage where Jido.Agent buys
nothing. As of v0.23, `IntentAgent`,
`Confirmations.Store.Agent`, and `Jobs.Scheduler.Agent` are Jido agents;
v0.24 adds `Objectives.Engine.Agent`. `Confirmations.Store` remains Allbert
Home file-backed, not SQLite-backed. `Jobs.Scheduler` remains
SQLite-job-backed and keeps no authoritative in-memory job queue. `Settings`,
`Trace`, `Memory` storage IO, `Session.Scratchpad`, `Memory.Compiler`, and
`Memory.Promotion` stay plain GenServers/modules. New modules document their
substrate choice in the module `@moduledoc`. Private Jido command modules
inside these agents are not registered Allbert capability actions and must not
appear in intent candidates. Worked conversion details live in
`docs/developer/jido-agent-pattern.md`. Transitional compatibility modules
used during v0.23 parity testing were removed before release closeout, while
retained fixture snapshots under `apps/allbert_assist/test/fixtures/v0.23/`
document canonical confirmation audit and scheduler summary behavior.

### Objectives And Advisory Providers (v0.24)

The objective runtime is the durable cross-turn substrate. `Objectives`
hold acceptance criteria and status; `Objectives.Step` records
per-step work; `Objectives.Event` records lifecycle history.
`Objectives.Engine.Agent` is a JidoBacked agent implementing a
seven-stage state machine: receive → interpret intent → frame/resume
objective → propose and evaluate steps → authorize → execute → observe
and advance. The seven-stage pipeline is implemented by 10 real private
`AllbertAssist.Objectives.Commands.*` `Jido.Action` modules routed through
JidoBacked signal dispatch; they are not registered actions and must not appear
as intent candidates. Do not define custom `cmd/3` functions on a JidoBacked
agent; `use Jido.Agent` already provides that API.

Facade rule: use `AllbertAssist.Objectives.list/2`, `get/2`, `frame/2`,
`advance/2`, `cancel/3`, `continue/2`, or registered objective actions for
lifecycle transitions. The lower-level create/update/list helpers in the same
module are internal store helpers. `frame/2` requires explicit user identity.

Authority rule (ADR 0021): `objective_id` is not permission;
`active_app` on an objective is not permission; advisory provider
output (LLM proposers, world-model predictors, diffusion proposers,
market allocators, probabilistic critics) is never authority. Everything
effectful flows through `Actions.Runner.run/3` and Security Central.
Objective-driven `RunAnalysis` or other app actions must still use the
registered action runner path; the objective engine never calls
confirmation storage directly.

Delegate rule: `AllbertAssist.Objectives.AgentRegistry` is a monitored local
registry. It evicts dead registered agent processes and dispatches through
`Jido.AgentServer.call/3`; plugins should not keep their own hidden delegate
agent lookup tables.

Durability rule: JidoBacked state is a rebuildable projection. Hybrid
proposer continuation state is stored in durable
`objectives.proposer_hint` JSON and only cached in
`Engine.Agent.proposer_hints`. Crash/rehydrate behavior should reload
from SQLite, not from serialized agent state.

Signal rule: v0.24 preserves legacy `allbert.input.received` and
`allbert.agent.responded` emissions and adds canonical
`allbert.runtime.turn.started` / `allbert.runtime.turn.completed`
aliases. Objective signals publish through the named
`Jido.Signal.Bus` (`AllbertAssist.SignalBus`); web subscribers use
`allbert.objective.**`, not `allbert.objective.*`. SignalBridge lives
in the web app and broadcasts objective events to per-user PubSub
topics; the engine remains Phoenix-agnostic.

ADR accounting: v0.24 M2 amends ADR 0019 to register the `:objective`
candidate kind. v0.24 M6 moves ADR 0021 to Accepted after confirming
the implemented `:objective_write`, `parent_step_id`,
`objectives.proposer_hint`, minimal `:delegate_agent`, `:abandoned`,
signal, and confirmation-threading contracts.

Reserved vocabulary: capability inventory, capability gap, route,
acquisition option, world-model provider, diffusion proposer, market
allocator. Named in ADR 0021; not implemented in v0.24. Research note
at `docs/research/objective-runtime-research.md`.
