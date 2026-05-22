# Changelog

## How Agents Should Use This File

Use this changelog as shipped-history context. Search by version or subsystem
when a task touches released behavior. ADRs, active plans, tests, and code are
more authoritative for current design and implementation. Do not bulk-read old
plans unless the task requires historical detail.

Do not add AI-tool attribution, co-author trailers, or generated-by footers to
changelog entries or release notes.

## v0.27.0 - App Surface Contract: StockSage LiveViews

Status: implemented and ready for operator manual verification. Version
metadata is `0.27.0`; release tag `v0.27.0` is pending operator acceptance.

Plan: `docs/plans/v0.27-plan.md`.
Request flow: `docs/plans/v0.27-request-flow.md`.

### Added (v0.27.0)

- StockSage-owned `/stocksage`, `/stocksage/analyses`,
  `/stocksage/analyses/:id`, `/stocksage/queue`, and `/stocksage/trends`
  LiveViews mounted through the host router and declared by
  `StockSage.App.surfaces/0`.
- Real StockSage renderers for the four v0.26-reserved app card atoms:
  `:analysis_card`, `:agent_report_card`, `:parity_card`, and
  `:debate_round_card`.
- `RunAnalysis` completed/failed responses now include validated
  `surface_nodes` for StockSage-owned app surfaces while preserving existing
  action fields and workspace fragment emission.
- StockSage memory namespace declaration/registration with `writable: false`;
  v0.27 claims ownership only and does not add memory sync or lesson
  promotion.
- Analysis detail pages render persisted cards, objective state, delegate
  steps, pending confirmation links, and cancel affordances.
- Bounded progress streaming via Phoenix.PubSub topic
  `stocksage_progress:<user_id>:<analysis_id>`, with reconnect catch-up from
  persisted objective/analysis state.
- Shared StockSage app navigation, empty/error/loading states, focus-visible
  affordances, and local workspace/queue/trends list rendering.

### Changed (v0.27.0)

- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, child app metadata,
  `StockSage.App.version/0`, `StockSage.Plugin.version/0`, and
  `plugins/stocksage/allbert_plugin.json` are bumped to `0.27.0`.
- Tailwind now scans `plugins/stocksage/lib/stocksage_web`, so plugin-owned
  LiveView modules receive generated responsive utility classes.
- `stocksage.web.enabled=false` keeps routes mounted but renders the bounded
  disabled state after Settings Central checks.

### Verification (v0.27.0)

- Milestone-focused tests passed after each implementation checkpoint:
  StockSage provider/settings tests, namespace registry tests, card renderer
  tests, `RunAnalysis` surface-node tests, objective/confirmation rendering
  tests, progress streaming tests, and StockSage LiveView app-flow tests.
- M7 Chrome extension verification covered `/stocksage`,
  `/stocksage/analyses`, `/stocksage/analyses/ana_missing`,
  `/stocksage/queue`, and `/stocksage/trends`; the pass caught and fixed the
  missing Tailwind plugin source path and a stale progress panel on missing
  analysis pages.
- Final release gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  and `mix precommit`.
- M8 release-gate cleanup removed an unreachable generic error branch from
  `StockSage.SurfaceNodes.validate_nodes/1` and updated an intent-candidate
  test diagnostic to handle v0.27 surface candidates alongside action
  candidates.

### Manual Verification (v0.27.0)

Use a disposable Allbert Home:

1. Run `ALLBERT_HOME="$SMOKE_HOME" mix ecto.migrate.allbert`, then
   `ALLBERT_HOME="$SMOKE_HOME" mix phx.server`.
2. Browse `/stocksage`, `/stocksage/analyses`, `/stocksage/queue`, and
   `/stocksage/trends`; verify navigation, empty states, and disabled-state
   behavior by setting `stocksage.web.enabled=false`.
3. Run a fixture StockSage analysis, approve the confirmation, open
   `/stocksage/analyses/<analysis_id>`, and verify real cards, objective
   state, confirmation/cancel affordances, and progress rows.
4. Refresh the analysis detail page and verify persisted progress and final
   state catch up without relying on live PubSub history.

---

## v0.26.2 - Workspace UX Closeout

Status: implemented and ready for operator manual verification. Version
metadata is `0.26.2`; release tag `v0.26.2` is pending operator acceptance.

Plan: `docs/plans/v0.26c-ux-closeout-plan.md`.
Request flow: `docs/plans/v0.26c-request-flow.md`.

### Added (v0.26.2)

- Real workspace tile inspector modal for existing canvas tiles. The Inspect
  action opens a focus-trapped dialog with tile metadata, body content,
  provenance, optional trace affordance, and copy controls.
- AppBar thread switcher dropdown replacing the copy-only thread chip. The
  menu lists recent local-user threads, creates a new thread through
  `Conversations.resolve_thread/1`, switches back to prior threads, and keeps
  copy-thread-id available in the menu.

### Changed (v0.26.2)

- `CopyToClipboard` stops click propagation so copy actions inside click-away
  menus can complete without closing their parent menu first.
- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, and child app
  metadata bumped to `0.26.2`.

### Verification (v0.26.2)

- Focused tests passed:
  `agent_live_test.exs` (35 tests), `renderer_test.exs` (9 tests), and
  `tile_inspector_test.exs` (1 test).
- Release gate passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  and `mix precommit`. The final `mix precommit` run reported 754 core tests,
  82 web tests, 168 StockSage plugin tests, and 2 channel plugin tests, all
  with 0 failures.
- Chrome browser smoke used two tabs on the same `/agent` thread. A pending
  approval ephemeral created in tab 1 appeared in tab 2 without reload; a
  StockSage objective canvas tile created in tab 1 appeared in tab 2 without
  reload; the inspector opened/closed on that real tile; the thread switcher
  copied the id, created a new thread, and switched back; Chrome console errors
  were empty.

### Manual Verification (v0.26.2)

Use a disposable Allbert Home, run migrations, start Phoenix, then open
`/agent` in Chrome:

1. Create a canvas tile, open the tile kebab, choose Inspect, verify focus
   enters `#workspace-tile-inspector`, provenance/body/copy controls render,
   and Escape closes it.
2. Open the thread switcher, copy the thread id, create a new thread, and
   switch back to the original thread.
3. Open the same thread in a second tab and confirm tile plus ephemeral updates
   converge without reload.

---

## v0.26.1 - Workspace UX/UI + Backend Runtime Closeout

Status: released and tagged as `v0.26.1` on 2026-05-22. This release
combines the v0.26a workspace UX/UI substrate pass with the v0.26b backend
runtime bugfix pass. Version metadata is `0.26.1`.

Plans:

- `docs/plans/v0.26a-ui-plan.md`
- `docs/plans/v0.26b-backend-plan.md`

### Fixed (v0.26b)

- Runtime intent fallback now recognizes generic safe setting-shaped prompts
  such as `set workspace.theme to dark` and routes them through
  `update_setting` even when no LLM key is configured.
- Secret-shaped, unsafe, and read-only setting prompts do not leak raw values;
  the existing Settings Central schema/action boundary owns validation and
  refusal.
- Native StockSage LLM preflight failures now surface bounded
  `native_llm_unavailable: ...` reasons through the native analysis failure
  path, persisted analysis metadata, action result, signal payload, and
  workspace fragment metadata.
- Disabling `stocksage.native_llm_enabled` still preserves deterministic
  fixture/smoke paths; v0.26b does not add automatic Python fallback.
- Fresh `/agent` composer state starts empty and uses neutral placeholder copy
  (`"Ask Allbert anything…"`).

### Verification (v0.26.1)

- `mix precommit` on merged `main`: 754 core tests, 79 web tests, 168
  StockSage plugin tests, and 2 channel plugin tests, all 0 failures.
- `mix credo --strict`, `mix compile --warnings-as-errors`, and formatter
  checks passed as part of the precommit gate.

---

## v0.26a - Workspace UX/UI Substrate Pass

Status: implemented through M35 closeout on 2026-05-21. Version metadata is
`0.26.1`. Fast-follow visual + interaction layer on top of the v0.26
workspace substrate; the substrate itself (catalog, schema, signals,
settings, permission classes, fragment validation, AGUI bridge, offline
editor) is unchanged.

Plan: `docs/plans/v0.26a-ui-plan.md`.

### Added (v0.26a)

- Live chat history accumulates without navigation. `handle_async(:ask, ok)`
  refreshes `conversation_messages`, `canvas_tiles`, and
  `ephemeral_surfaces` so prior turns stay visible as new turns land (M28).
- Composer clears on submit; Enter submits and Shift+Enter newlines via a
  new `ComposerEnter` JS hook that respects IME composition and modifier
  keys. Character counter mirrored from
  `workspace.canvas.tile_body_max_bytes` flips to a warn color at 90% of
  cap (M29).
- `ChatAutoScroll` JS hook pins the chat timeline to the bottom on append
  unless the operator has scrolled away.
- `CopyToClipboard` JS hook reused across the AppBar thread chip, runtime
  signal / trace ids, the approval modal confirmation id, every card
  footer's external-id chip, and the tile kebab "Copy tile id" entry.
- Sticky AppBar plus independently scrolling chat / canvas panes — the
  workspace shell is now a `100dvh` flex column rather than a normal-flow
  page (M30).
- Mobile tab strip stays sticky just below the AppBar at `< 768px` so the
  toggle is reachable while reading long chat history. Pane heights
  retightened to `calc(100dvh - 9rem)` to suit the sticky chrome (M31).
- Approval handoff renders as a centered modal overlay with a translucent
  backdrop scrim, dark-mode and reduce-motion variants, and a copy chip
  on the confirmation id. Authority is unchanged (approve / deny still
  route through registered actions) (M32).
- Every catalog card derived from `Base.render_simple/1` renders a status
  pill driven by `prop(:status)` / `prop(:lifecycle_kind)` / `prop(:state)`
  using `workspace-status-success` / `-info` / `-warn` / `-danger` /
  `-neutral` variants. Card footers carry an external-id chip
  (objective / confirmation / analysis / tile) that copies to clipboard
  on click (M33).
- AppBar overflow `…` is no longer disabled. Clicking opens a popup menu
  with the theme cycle, Workspace settings, Scheduled jobs, and Objectives
  links; uses LiveView state, no JS hook required.
- AppBar chips now navigate: thread chip copies the full thread id;
  objective chip links to `/objectives`; tile chip jumps to the canvas
  anchor; ephemeral chip jumps to the ephemeral anchor.
- 3-state theme cycle (system → dark → light → system) with the icon and
  label updating per state (M34).

### Changed (v0.26a)

- `AllbertAssist.App.CoreApp.version/0`, umbrella metadata, and child app
  metadata bumped to `0.26.1`.
- `Workspace.Fragment.emit/1` now logs the exception struct + message when
  the persistence rescue trips, so the bounded `:exception` drop reason
  becomes actionable. (The previous lack of detail made a test-suite
  sandbox connection-ownership leak look identical to a production bug.)
- Composer placeholder rewritten from `"Ask the agent something..."` to
  `"Ask Allbert anything…"`.
- Timeline timestamps render as relative time
  (`just now / 2m ago / Mar 04 14:32`) with full ISO retained on the
  `<time datetime>` attribute for accessibility.

### Verification (v0.26a)

- `mix test apps/allbert_assist_web/`: 79 tests, 0 failures (includes the
  new responsive + agent_live + composer assertions).
- `mix format --check-formatted`, `mix credo --strict`,
  `mix compile --warnings-as-errors`: all clean on commit.
- Browser-driven smoke confirmed the pre-M28 audit
  findings reproduced cleanly under the old code and that M28–M34 fixes
  resolved them. The v0.26.1 closeout records the final merged-main gate.

### Bugs flagged for separate triage (resolved by v0.26b)

- H1 (runtime): the intent agent falls through to `direct_answer` for
  clearly setting-shaped prompts (`"Set workspace.theme to dark"`) when
  no LLM API key is configured. The deterministic fallback should
  pattern-match `set <key> to <value>` and route to `update_setting`.
  Resolved in v0.26b.
- H2 (stocksage): native StockSage analysis transitions silently to
  `:failed` when no LLM key is configured. The failure reason should
  surface in the chat or via an ephemeral. Resolved in v0.26b through the
  native failure/action/signal/workspace-fragment path.
- H3 (runtime): the default LiveView prompt placeholder used to be content
  copy; M28 moved it into the empty-state callout, but CLI surfaces
  should follow. Resolved in v0.26b for the `/agent` composer state and
  placeholder.

---

## v0.26 - Agentic Workspace Surface And Ephemeral UI Substrate

Status: implemented through M30 UI release closeout on 2026-05-19 and
superseded by the accepted `v0.26.1` closeout. Version metadata was `0.26.0`
for the base workspace release and moved to `0.26.1` in the v0.26a/v0.26b
follow-up.

### Added (v0.26)

- `/agent` is now the Allbert workspace: a `CoreApp` Surface tree rendered by
  catalog-dispatched LiveComponents rather than a prompt-only page.
- Per-thread canvas tiles and per-thread ephemeral surfaces backed by SQLite
  metadata plus YAML bodies under Allbert Home.
- Runtime Fragment emission through signed, strictly validated
  `Workspace.Fragment.Envelope` payloads and `allbert.workspace.fragment.**`
  SignalBus topics.
- A 42-component workspace catalog: v0.18 carryover components, workspace
  structural nodes, Allbert-domain cards, app cards, and reserved StockSage
  card stubs for v0.27 rendering work.
- Workspace Mix tasks for inspect, canvas list/show/pin/unpin/restore/purge,
  ephemeral list, and signing-secret rotation.
- Dark/light workspace theme toggle, high-contrast and reduced-motion support,
  WCAG-oriented structural coverage, mobile tabs, and responsive two-pane
  layout. The mobile breakpoint is fixed at 768px and read-only in v0.26.
- Allbert-owned `/agent` chrome: AppBar identity, thread/active-app/status
  chips, slate-blue workspace tokens, soft stale-thread recovery notices, and
  a client-side-only chat/canvas split bar with pointer and keyboard support.
- Workspace-scoped service worker, offline shell fallback, browser-side Yjs +
  IndexedDB text/markdown tile editing, bounded reconnect sync, server-side
  revision snapshots, conflict banner, and `revert_tile_revision`.
- Internal `AllbertAssist.Workspace.AGUI.Bridge` mappings from curated Allbert
  signals to AG-UI event shapes for test-only semantic validation.

### Changed (v0.26)

- `AllbertAssist.App.CoreApp.version/0`, umbrella app metadata, and child app
  metadata are release-pinned to `0.26.0`.
- `AllbertAssist.App.CoreApp.surfaces/0` now declares the workspace shell at
  `/agent`; sibling routes remain available for deep links.
- Trace output includes workspace sections and fragment/tile activity where a
  runtime turn touches workspace state.
- ADR 0023 is Accepted and records the shipped workspace canvas and ephemeral
  surface substrate; ADR 0015's v0.26 catalog amendment is confirmed.
- M21-M26 post-review remediation bound `/agent` to real conversation
  threads, emitted runtime/objective Fragments, moved Fragment persistence out
  of LiveView, routed workspace writes through registered actions, synced
  ephemeral lifecycle events across tabs, enforced tile body limits, made
  reduced-motion effective, and made the unsupported dynamic mobile breakpoint
  read-only.
- M28-M29 replaced Phoenix scaffold leftovers and placeholder/debug-card
  renderers with Allbert Assist chrome, operator chat/canvas panes, polished
  tile shells, hidden empty badge/ephemeral regions, useful catalog cards,
  accessible tabs, and the browser-local split separator. This is visual
  polish over the existing v0.26 substrate; it does not add security authority.

### Safety (v0.26)

- Workspace effects still route through registered actions, `Actions.Runner`,
  Security Central, confirmations where required, and audit/traces. Surface
  metadata, fragments, apps, plugins, and generated files do not grant
  permission.
- Fragment validation enforces envelope shape, HMAC signature, catalog
  membership, emitter allow-list, per-emitter rate limit, and payload size
  before anything renders.
- Offline tile editing accepts only text/markdown tiles, bounds payload size,
  enforces canvas tile-body limits for snapshots, stores browser Yjs payloads
  opaquely, keeps readable server snapshots, and preserves rejected/corrupt
  local drafts for fallback-shell recovery instead of silently deleting them.
- No public AG-UI/A2UI/MCP Apps bridge ships in v0.26.

### Verification (v0.26)

- Milestone-focused suites covered workspace catalog, canvas/ephemeral
  persistence, Fragment validation/signing, AG-UI bridge mappings, trace
  integration, CLI tasks, theme/accessibility/responsive behavior, offline
  editor hooks, reconciliation, and revert action behavior.
- Disposable-home browser smokes covered the rendered workspace, component
  catalog, fragment flow, multi-tab sync, theme/a11y/mobile behavior,
  service-worker offline shell, IndexedDB draft restore, and stale-base
  conflict/revert behavior.
- Final gates passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.
- Final M30 `mix precommit` passed with 746 core tests, 71 web tests,
  165 StockSage plugin tests, and 2 channel plugin tests.
- Post-review fixes added the registered
  `workspace.fragment.receiver_rate_limit_per_second` setting, a short
  previous-secret verification overlap for workspace Fragment signing-key
  rotation, explicit release-gate wording that `mix precommit` includes
  plugin tests while bare `mix test` does not, and removed vestigial
  min/max bounds from the read-only `workspace.mobile.breakpoint_px` schema.
- M30 adds manual UI validation instructions for desktop, mobile, theme,
  stale-thread recovery, StockSage active-app routing, canvas/tile states,
  ephemeral overlays, offline behavior, resize behavior, accessibility, and
  cross-browser smoke. The v0.26.1 closeout is the accepted release tag.

## v0.25 - Native Financial Specialist Agents

Status: implemented through M6 closeout on 2026-05-17 and ready for
operator manual verification. Version metadata is `0.25.0`.

### Added (v0.25)

- StockSage native financial specialist-agent graph: 11 supervised
  LLM-capable `Jido.AI` specialists, 1 deterministic quality gate, and the
  `StockSage.Agents.NativeCoordinator` JidoBacked orchestrator under
  the StockSage plugin supervisor.
- Explicit research-manager and trader-plan handoffs in the native graph,
  preserving the Python TradingAgents research/trader/portfolio-manager
  sequence more closely than the earlier collapsed synthesizer shape.
- Native analysis is now the default `run_analysis` engine. Explicit
  Python comparison remains available only by request (`--engine python`,
  `--engine both`, or `--compare-python`) and is gated by
  `stocksage.python_comparison_enabled`.
- Five action-backed evidence providers under `StockSage.Actions.Evidence.*`
  with fixture mode, Resource Access posture, and the
  `:stocksage_evidence_fetch` permission class.
- Multi-round bull/bear/risk debate with Settings-bounded caps and one
  durable `objective_steps` row per specialist turn.
- `--engine both` parity runs that fan out native + Python comparison,
  compute 5-point rating agreement plus confidence delta, and persist
  `parity_diff` JSON on the analysis row.
- A bounded committee-context ledger for the final decision synthesizer,
  including ordered specialist stances, rating counts, risk-committee
  summaries, and cautious-report excerpts.
- Core `mix allbert.delegate <agent_id>` task, proving any registered
  objective delegate agent can be invoked through the shared action
  boundary outside StockSage.

### Changed (v0.25)

- `StockSage.Actions.RunAnalysis` creates native objectives, persists
  native/parity details, labels explicit Python comparison clearly, and
  never falls back from native to Python automatically.
- StockSage agent prompts and prompt provenance live under
  `plugins/stocksage/priv/prompts/native_agents/` with v0.25 prompt
  version metadata.
- `stocksage.native_llm_enabled` controls whether non-quality native
  specialists call Jido.AI or use deterministic advisory packets for
  tests/operator smoke.
- Native/Python parity tuning is improved but not finished: v0.25 avoids
  ticker-specific correction logic and deterministic rating floors, and
  leaves deeper evidence-source and prompt/agent calibration as future work.
- StockSage plugin, app, manifest, CoreApp, and umbrella app versions
  are release-pinned to `0.25.0`.
- ADR 0022 is Accepted and records the shipped topology, coordinator
  loop, parity metric, evidence-action posture, and delegate CLI proof.

### Verification (v0.25)

- Focused suites passed for prompt inventory, specialist registry,
  evidence actions, native coordinator single and multi-round analysis,
  parity scoring/persistence, `mix allbert.delegate`, and StockSage CLI
  smoke paths.
- Final gates passed: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`,
  `mix dialyzer`, `mix precommit`, and `git diff --check`.
- `mix precommit` passed with 683 core tests, 27 web tests, 165
  StockSage plugin tests, and 2 delegate task smoke tests.

## v0.24 - Objective Runtime Foundation

Status: released and tagged as `v0.24` on 2026-05-17 after post-audit
hardening and release verification. Version metadata is `0.24.0`.

### Added (v0.24)

- Durable objective runtime tables: `objectives`, `objective_steps`, and
  `objective_events`, plus nullable `objective_id` / `step_id` links on
  confirmations, scheduled jobs, StockSage queue rows, and StockSage analyses.
- `AllbertAssist.Objectives.Engine.Agent`, a JidoBacked seven-stage
  coordinator backed by 10 real private command modules for receiving a turn,
  framing/resuming an objective, proposing and evaluating steps, authorizing
  through the existing action boundary, executing, observing, advancing,
  continuing, cancelling, and pruning stale objectives.
- Registered objective actions:
  `list_objectives`, `show_objective`, `continue_objective`, and
  `cancel_objective`, surfaced through `mix allbert.objectives`.
- `:objective_write` permission class and objective runtime settings for the
  master switch, loop caps, stale abandonment window, and max steps per turn.
- Deterministic acceptance evaluator, durable hybrid proposer hints, and the
  first app proposer (`StockSage.Proposer`) proving a one-step analysis and a
  two-step "analyze AAPL and compare to MSFT" flow.
- Minimal `:delegate_agent` step contract and monitored
  `AllbertAssist.Objectives.AgentRegistry` as the v0.25 handoff for
  specialist agents; dead delegate-agent entries are evicted automatically.
- Objective lifecycle signals, canonical runtime turn signal aliases, and the
  web-side `AllbertAssistWeb.SignalBridge` that fans objective signals into
  per-user Phoenix.PubSub topics.
- `/agent` active-objective badges and `/objectives/:id` inspection/cancel
  surface. LiveViews remain thin consumers of registered actions.

### Changed (v0.24)

- StockSage `RunAnalysis` and queue/analysis rows now preserve
  `objective_id` and `step_id` context when invoked from an objective.
- Confirmation renderers for CLI, SettingsLive, Telegram, and email now show
  objective title/status context and a stale-warning note when the linked
  objective has moved since confirmation creation.
- `Intent.Engine.collect_candidates/2` now accepts objective context and ADR
  0019 registers `:objective` as a proposal-only candidate kind.
- Trace rendering now includes inline objective context and a bounded
  `## Objective Steps` section for turns that touch objective work.
- `AllbertAssist.Objectives` now exposes the public lifecycle facade
  (`list/2`, `get/2`, `frame/2`, `advance/2`, `cancel/3`, `continue/2`) while
  retaining lower-level store helpers for the engine.
- `mix allbert.objectives` now enforces documented OS exit codes for usage,
  not-found, identity mismatch, and unexpected action/security failures via a
  test-injectable halt function.
- `AllbertAssist.App.CoreApp.version/0`, umbrella app metadata, and
  StockSage plugin/app metadata are release-pinned to `0.24.0`.

### Safety (v0.24)

- `objective_id`, `step_id`, and `active_app` are never permission. Every
  effectful objective step still executes through `Actions.Runner.run/3`,
  Security Central, resource posture, and durable confirmations.
- The objective engine never writes confirmation YAML directly and never
  calls app internals for effectful work.
- Private objective command modules remain internal Jido engine commands and
  are not registered in `AllbertAssist.Actions.Registry`.
- Cancellation is cooperative only. Pending/proposed/selected/blocked steps
  can be cancelled; already approved in-flight work is not interrupted.
- Advisory provider, world-model, diffusion, market-allocation, and
  capability-inventory vocabulary remains reserved only. v0.24 ships no
  external advisory provider calls, no parallel execution, no dynamic
  planner, and no authority transfer to model output.

### Verification (v0.24)

- Milestone suites passed for objective schemas/migrations/settings,
  JidoBacked engine setup, all 10 private command modules, framing/resume,
  StockSage proposer integration, confirmation threading, continuation,
  delegation, cancellation, channel rendering, LiveView surfaces, and
  SignalBridge behavior.
- Hardening tests now cover directive-returning command paths, objective
  facade identity scoping, delegate-agent dead-entry cleanup, real CLI exit
  codes, migration up/down reversal, inline trace placement, Telegram/email
  plugin objective rendering, ObjectiveLive terminal/cross-user/PubSub paths,
  SignalBridge subscription failure, evaluator matrix cases, and engine
  proposer-hint rehydration.
- M5 focused suite passed with allbert_assist 42 tests and
  allbert_assist_web 7 tests, 0 failures.
- Closeout gates passed: `git diff --check`, `mix format
  --check-formatted`, `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer` (0 unskipped errors),
  `mix test` (`allbert_assist` 673 tests and `allbert_assist_web`
  27 tests), StockSage plugin tests (123 tests), Telegram/email plugin
  renderer tests (2 tests), and `mix precommit`.
- Operator smoke steps live in `docs/plans/v0.24-request-flow.md`.
- Release tag: `v0.24`.

## v0.23 - Jido State-Machine Convergence

Status: implemented and ready for operator manual verification. Version
metadata is `0.23.0`; the release tag is pending operator acceptance.

### Added (v0.23)

- `AllbertAssist.JidoBacked` shared substrate for internal state-machine
  coordinators that are implemented as `Jido.Agent` instances but keep their
  existing durable stores as the source of truth.
- `AllbertAssist.JidoBacked.Supervisor` under the core application
  supervision tree, currently hosting `Confirmations.Store.Agent` and
  `Jobs.Scheduler.Agent`.
- Jido-backed `AllbertAssist.Confirmations.Store.Agent` with private
  `Jido.Action` command modules for create/read/list/resolve/expire/rebuild.
  Confirmation YAML and audit markdown under Allbert Home remain authoritative.
- Jido-backed `AllbertAssist.Jobs.Scheduler.Agent` with private scheduler
  commands for run-once, stale-run cleanup, tick, and scheduled next tick.
  SQLite `scheduled_jobs` and `scheduled_job_runs` rows remain authoritative.
- `allbert.jido.debug_trace` Settings Central key, default `false`. When
  enabled alongside trace recording, trace markdown includes a bounded
  `## Jido Debug` section for the converted coordinators.
- `docs/developer/jido-agent-pattern.md` and updated development/agent context
  docs describing the pragmatic rule for choosing `Jido.Agent` vs plain
  `GenServer`.

### Changed (v0.23)

- `AllbertAssist.Confirmations.Store` and `AllbertAssist.Jobs.Scheduler` are
  now public facades over Jido-backed agents. Their public API, CLI behavior,
  action behavior, audit shapes, and durable storage locations are preserved.
- `AllbertAssist.Application` starts scheduler coordination through
  `AllbertAssist.JidoBacked.Supervisor` rather than a separate scheduler child.
- Transitional compatibility modules used during parity testing were removed
  before release closeout.

### Safety (v0.23)

- Private command actions are not registered capabilities, not intent
  candidates, and not operator-callable actions. All effectful public behavior
  still goes through the existing registered action runner and Security
  Central boundaries.
- `Jido.Agent` is not treated as a security boundary. Durable confirmations
  remain file-backed; scheduled jobs remain SQLite-backed; permissions and
  confirmations remain enforced at the public action boundary.
- Default operator traces remain unchanged. Jido debug details appear only
  after explicitly enabling `allbert.jido.debug_trace`, and the emitted
  metadata is bounded and redacted.

### Verification (v0.23)

- Focused suites passed for JidoBacked helpers/supervision, confirmation-store
  agent parity, confirmation public actions/CLI, scheduler agent behavior,
  jobs public API/CLI/LiveView consumers, convergence integration flows,
  channel simulation flows, memory confirmation actions, and StockSage
  `RunAnalysis` confirmation behavior.
- Retained v0.23 fixture snapshots cover canonical confirmation audit output
  and scheduler summary output under
  `apps/allbert_assist/test/fixtures/v0.23/`; `StoreGoldenTest` and
  `SchedulerGoldenTest` read those fixtures as release regression coverage.
- Closeout gates passed: focused v0.23 M1-M4 suites, full `mix test`,
  plugin `RunAnalysis` regression, `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, deleted-module grep gate, and `git diff --check`.
- Operator smoke steps live in `docs/plans/v0.23-request-flow.md`.

## v0.22 - StockSage Python Bridge

Status: released and tagged as `v0.22` on 2026-05-16 after M5 closeout,
operator audit closeout, and post-implementation gap fixes. Version metadata
is `0.22.0`.

### Added (v0.22)

- `StockSage.Bridge.Protocol` and `./plugins/stocksage/priv/python/bridge.py`
  implement the ADR 0020 JSON-over-stdio envelope for the supervised Python
  bridge. The bridge supports `ping` and `run_analysis` actions and bounds
  responses with `stocksage.bridge_max_output_bytes`.
- `StockSage.TraderBridge` GenServer owns a long-lived Erlang `Port` to
  `bridge.py`, isolates Port crashes with `{:error, :bridge_crashed}`, and
  honours `stocksage.bridge_enabled`, `stocksage.bridge_timeout_ms`, and
  `stocksage.python_path` from Settings Central. The bridge runs under
  `StockSage.Supervisor` as a plugin-owned child contributed via
  `StockSage.Plugin.child_spec/1`.
- `StockSage.Actions.RunAnalysis` registered through
  `StockSage.Plugin.actions/0` as a `resumable?: true` Jido action gated by
  the new `:stocksage_analyze` permission. The action validates ticker (regex,
  ≤10 chars) and ISO-8601 analysis date, creates a durable confirmation
  record on the first call, and runs the bridge on the approved resume path
  through `AllbertAssist.Actions.Confirmations.ApproveConfirmation`. Bridge
  success persists `stocksage_analyses` (+ `stocksage_analysis_details`)
  rows; bridge errors persist a `status: failed` analysis row.
- `:stocksage_analyze` permission class added to `AllbertAssist.Security.Policy`
  and `AllbertAssist.Security.Risk` with default `needs_confirmation`, safety
  floor `needs_confirmation` (cannot be lowered to `allowed` via settings),
  and risk tier `high`.
- `permissions.stocksage_analyze` setting registered in the core schema with
  `allowed_values: ["needs_confirmation", "denied"]`. Five new
  `stocksage.bridge_*` and `stocksage.analysis_engine` settings added to the
  StockSage plugin settings schema.
- `mix stocksage.analyze TICKER ANALYSIS_DATE [--user] [--engine] [--queue-id]`
  CLI prints the confirmation id on first call and completed analysis
  metadata after approval. `--queue-id` links a queue entry to the run.
- `AllbertAssist.Trace` renders a new `## StockSage Analysis` section with
  bounded action metadata (action, status, ticker, analysis date, engine,
  analysis id, bridge duration, truncated, summary ≤ 200 chars).
- New `run-analysis` skill declares the `run_analysis` action,
  `:stocksage_analyze` permission, confirmation requirement, and example
  prompts. The skill is discoverable via the v0.19 engine when
  `active_app: :stocksage`.

### Safety (v0.22)

- Bridge execution requires confirmation by default. The `:stocksage_analyze`
  safety floor is `:needs_confirmation` and cannot be lowered via settings.
- TradingAgents external market-data API calls are included in the operator's
  approval scope and disclosed in the confirmation record. Per-source
  Resource Access Security Posture for those calls is deferred to v0.28
  (formerly v0.26 before the project-direction rethink renumber).
- Raw bridge output is bounded by `stocksage.bridge_max_output_bytes` and
  never appears in traces, CLI list summaries, or signals. Only bounded
  summaries (≤500 chars in `stocksage_analyses.summary`, ≤200 chars in
  trace `## StockSage Analysis`) are surfaced. `show_analysis` returns only
  the vetted detail payload fields (`engine`, `stub`, `truncated`) and never
  exposes arbitrary imported `payload_json`.
- Bridge crashes and timeouts do not propagate to Allbert core supervision;
  callers receive bounded `{:error, :bridge_crashed}` / `{:error, :timeout}`.
- Setting `stocksage.bridge_enabled = false` short-circuits RunAnalysis before
  any confirmation record is created.
- All bridge code lives under `./plugins/stocksage/`. Allbert core does not
  import bridge internals; the only core touchpoints are
  `AllbertAssist.Actions.Runner`, `AllbertAssist.Security`,
  `AllbertAssist.Actions.Registry`, and `AllbertAssist.Repo`.

### Verification (v0.22)

- Focused suites passed for `StockSage.Bridge.ProtocolTest`,
  `StockSage.TraderBridgeTest` (tagged `:bridge`), `StockSage.SupervisorTest`,
  `StockSage.Actions.RunAnalysisTest` (including the
  `approve_confirmation` end-to-end loop and bounded confirmation CLI target
  summary),
  `Mix.Tasks.Stocksage.AnalyzeTest`, the StockSage `ActionsTest` intent
  routing additions, `StockSage.TraceTest`, and the
  `AllbertAssist.Security.PermissionGateTest` additions for
  `:stocksage_analyze`.
- Closeout gates: `mix format --check-formatted`,
  `mix compile --warnings-as-errors`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Operator smoke confirmed (`mix stocksage.analyze AAPL 2026-05-01 --user
  local` → confirmation id → `mix allbert.confirmations approve <id>` →
  `stocksage_analyses` and `stocksage_analysis_details` rows persisted with
  bounded summary, confirmation resolved as approved).

## v0.21 - Memory Review And Retrieval

Status: implemented through M6 closeout and post-implementation gap fixes on
2026-05-15. Version metadata is `0.21.0`; the operator manual verification
matrix remains the release gate. Release tag is pending operator acceptance.

### Added

- Review-aware markdown memory entries with explicit `review_status`,
  reviewer, review timestamp, and correction notes.
- `mix allbert.memory` commands for listing, showing, searching, reviewing,
  updating, deleting, pruning, promoting conversation turns, compiling the
  memory index, and summarizing categories.
- Registered memory actions for review/correction/pruning/promotion, all
  routed through `Actions.Runner.run/3` and Security Central.
- Rebuildable derived memory artifacts: `.index.json` and category
  `.summary.md` files under the markdown memory root.
- Metadata-only `:memory` intent candidates from the compiled index, with
  trace rendering for bounded candidate metadata.
- `memory-index-rebuild` as a CLI-instantiated scheduled job template and as
  the managed job synchronized from `memory.review_cadence`.
- `memory.prune_requires_confirmation` to control bulk prune confirmation
  independently from single-entry delete confirmation.

### Safety

- Markdown memory remains the source of truth; SQLite conversation history is
  never auto-promoted.
- Delete, prune, and promote flows use durable confirmations by default, and
  deleted/pruned entries are archived under `memory/deleted/YYYY-MM/` rather
  than hard-deleted.
- Memory candidates are proposal data only. They do not grant permissions,
  authorize actions, or include entry bodies in intent traces. Candidate scores
  are capped at 0.5.
- Flagged and prune-nominated entries are excluded from search/index intent
  candidates.

### Verification

- Focused suites passed for memory entry parsing, review status round-trips,
  memory actions, promotion ownership checks, index/search/summary artifacts,
  trace rendering, intent memory candidates, job templates, and Mix tasks.
- Post-implementation focused suites added compiler edge-case tests, cadence
  job synchronization tests, prune-confirmation separation coverage, and the
  memory candidate score cap assertion.
- Final v0.21 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix credo --strict`, `mix dialyzer`, `mix precommit`, and
  `git diff --check`.
- Manual verification steps live in `docs/plans/v0.21-request-flow.md`.

## v0.20 - StockSage Plugin App And Domain

Status: implemented through M5 closeout fixes on 2026-05-15. Version metadata
is `0.20.0`; the operator manual verification matrix remains the release gate.
Release tag is pending operator acceptance.

### Added

- `./plugins/stocksage` as the first real shipped plugin app package with
  `StockSage.Plugin`, `StockSage.App`, skill roots, settings schema entries,
  and registered action contributions.
- Plugin-owned StockSage domain, action, import, CLI, and test modules under
  `./plugins/stocksage`; no `apps/stocksage` or `apps/stocksage_web` umbrella
  apps.
- Shared SQLite `stocksage_*` domain tables through `AllbertAssist.Repo`:
  analyses, analysis details, outcomes, queue entries, queue runs, and
  StockSage-local memory entries.
- `StockSage.Import.SqliteImporter` and `mix stocksage.import_sqlite` for
  read-only, idempotent import of the representative legacy SQLite fixture.
- Safe local actions `list_analyses`, `show_analysis`, `get_trends`, and
  `queue_analysis`, all contributed through `StockSage.Plugin.actions/0`.
- Operator CLIs `mix stocksage.analyses list/show` and
  `mix stocksage.queue create/list`.
- `mix allbert.skills list` for operator inspection of discovered skill
  manifests, including StockSage plugin provenance.
- `mix allbert.ask --active-app APP_ID` for one-turn CLI app context, used
  alongside volatile running-node session scratchpad context.
- `:stocksage_write` as a low-risk local domain write permission for queue and
  domain writes only.

### Safety

- StockSage uses the existing `AllbertAssist.Repo`; no `StockSage.Repo` or
  second database boundary was introduced.
- Every domain row carries `user_id`, and read-by-id paths require `user_id`;
  another user's durable id returns not-found.
- v0.20 does not execute Python, call market-data APIs, mount StockSage
  LiveViews, start native trading agents, or emit canvas components.
- `queue_analysis` creates only a durable local queue row. It does not start a
  worker or external process.
- Engine-selected registry actions from direct-answer fallbacks now execute
  through `Actions.Runner`; app affinity still does not grant permission.
- StockSage memory entries are SQLite domain records and are not automatically
  promoted into markdown Allbert memory.

### Verification

- Focused suites passed for plugin/app registration, domain schemas and
  contexts, legacy import, actions through `Actions.Runner`, settings schema
  merge, Security Central, and StockSage Mix tasks.
- Final v0.20 closeout gates passed: `mix test`,
  `mix test ../../plugins/stocksage/test/stocksage ../../plugins/stocksage/test/mix`
  from the host app, `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.20-request-flow.md`.

## v0.19 - Cross-Surface Intent Enrichment

Status: implemented through M6 closeout on 2026-05-15. Version metadata is
`0.19.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Registry-aware intent candidates for actions, skills, and registered app
  surfaces, with bounded selected/rejected candidate metadata in decisions.
- Active-app affinity and inert registered-surface navigation decisions for
  prompts such as opening the Allbert chat surface.
- Optional `AllbertAssist.Intent.Classifier` model-assist hook, disabled by
  default, with fake classifier tests and candidate-set validation.
- `explain_intent` and `list_intent_candidates` read-only internal actions for
  operator inspection.
- `## Intent Candidates` trace rendering with selected candidate, rejected
  candidates, app context, classifier diagnostics, and surface target metadata.

### Safety

- v0.11-v0.13 resource, confirmation, Approval Handoff, job, and channel
  behavior remains unchanged; risky prompts still route through their existing
  registered actions and resource posture before any surface fallback.
- `active_app`, plugin provenance, surface metadata, and model output are
  ranking/explainability inputs only. They do not grant authority or bypass
  Security Central.
- Model assistance cannot invent candidates, is off by default, and records no
  raw prompt or raw model completion in traces.

### Verification

- Focused suites passed for candidate validation, ranking, classifier fallback,
  runtime risky-route preservation, trace rendering, and intent-inspection
  actions.
- Final v0.19 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.19-request-flow.md`.

## v0.18 - Full App Contract And Surface DSL

Status: implemented through M6 closeout on 2026-05-15. Version metadata is
`0.18.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Full `AllbertAssist.App` contract callbacks for agents, signals, and
  settings schema metadata while preserving v0.15 minimal app compatibility.
- `AllbertAssist.App.SurfaceProvider` and the validated
  `AllbertAssist.Surface` DSL with nodes, action bindings, catalog validation,
  and the initial twelve-component catalog.
- `AllbertAssist.Surface.Encoder.to_a2ui/1` as a typed future adapter boundary
  that returns `{:error, :not_implemented}` without adding AG-UI/A2UI runtime
  dependencies.
- `AllbertAssist.App.CoreApp` as the first surface provider, declaring the
  existing `/agent` route as the built-in chat surface.
- `mix allbert.validate_app MODULE` and
  `docs/developer/how-to-create-an-allbert-app.md`.

### Changed

- Runtime turns now default to `active_app: :allbert` when no known request or
  scratchpad app context exists. Unknown app id strings fall back to `:allbert`
  with diagnostics and without atom creation.
- App registry entries now store agents, signals, settings schema entries,
  provider surfaces, and surface catalogs.
- `mix allbert.apps show` and the `show_app` action now expose v0.18 contract
  summaries without raw node trees or process internals.
- Settings Central now merges app and plugin settings schema contributions at
  read/validation time, closing the v0.17 schema-consumption gap.

### Safety

- App registration, provider surfaces, action bindings, and `active_app`
  context do not grant permissions or bypass Security Central.
- Surface validation rejects unknown components, duplicate node ids, non-local
  paths, secret-like props, raw HTML/script values, remote URL props, and
  unknown action bindings before registration.
- v0.18 does not add memory namespace registration, canvas rendering, dynamic
  route loading, generated UI execution, AG-UI/A2UI dependencies, or app/plugin
  generators.

### Verification

- Focused suites passed for the app contract, Surface DSL, app registry,
  settings schema merge, runtime active-app defaulting, app actions, and Mix
  app validation tasks.
- Final v0.18 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.18-request-flow.md`.

## v0.17 - Plugin Contract And Shipped Channel Plugins

Status: implemented through M6 closeout on 2026-05-14. Version metadata is
`0.17.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- `AllbertAssist.Plugin` behaviour, normalized plugin entries, manifest
  validation, plugin discovery, supervised plugin registry/bootstrap, and a
  plugin child supervisor.
- Static `plugins.*` settings schema and default scan paths for `./plugins`
  and `<ALLBERT_HOME>/plugins`.
- Shipped source-tree plugin packages for Telegram and email under
  `./plugins/allbert.telegram` and `./plugins/allbert.email`.
- Plugin-contributed skill roots, actions, apps, channel descriptors, settings
  schema metadata, and supervised child specs.
- Read-only registered actions `list_plugins` and `show_plugin`.
- `mix allbert.plugins list/show/diagnostics`.

### Changed

- Telegram and email provider-specific channel code moved out of the core app
  tree and into shipped source-tree plugin packages while preserving v0.16
  channel behavior and settings keys.
- `AllbertAssist.Channels` now reads channel descriptors from
  `AllbertAssist.Plugin.Registry` instead of a hardcoded provider map.
- `AllbertAssist.Actions.Registry` can merge trusted compiled
  plugin-contributed actions while stamping plugin provenance on capability and
  runner metadata.
- `AllbertAssist.App.Bootstrap` consumes plugin-contributed app modules.
- Version metadata and built-in app versions moved to `0.17.0`.

### Safety

- Plugins are discovery and packaging contracts, not authority. Plugin metadata
  does not grant permissions, trust, confirmations, resource access, or
  execution rights.
- v0.17 does not load arbitrary code from `<ALLBERT_HOME>/plugins`, run package
  managers during discovery, install remote plugins, hot-reload plugin code, or
  automatically compile arbitrary `./plugins/*/lib` folders.
- Plugin CLI/action output renders normalized metadata and contribution counts;
  it does not print raw manifests, provider payloads, or secret reference keys.

### Verification

- Milestone focused suites passed for plugin validation, manifest discovery,
  plugin registry/bootstrap, skill roots, channel descriptor migration,
  plugin-contributed apps/actions, and `mix allbert.plugins`.
- Final v0.17 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.17-request-flow.md`.

## v0.16 - Additional Channels

Status: implemented through M7 closeout on 2026-05-14. Version metadata is
`0.16.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Shared `AllbertAssist.Channels` substrate with durable `channel_events`,
  explicit external identity mapping, stable channel `session_id` derivation,
  and supervised channel adapters.
- Telegram Bot API long-polling adapter with bounded `Req` client, text and
  callback parsing, runtime submission, response rendering, inline approval
  buttons, callback acknowledgements, and restart offset derivation.
- Email IMAP/SMTP adapter with minimal TLS IMAP polling, `gen_smtp` outbound
  replies, MIME text parsing, typed confirmation commands, and Message-ID
  dedupe.
- Read-only registered actions `list_channels` and `show_channel`.
- `mix allbert.channels` for list/show, Telegram token storage, email password
  storage, identity map/unmap, local simulation, and bounded `poll-once`.

### Changed

- Runtime turns from Telegram and email preserve `channel`, external identity,
  resolved `user_id`, `session_id`, `thread_id`, input signal id, and trace id
  on channel event rows.
- Durable confirmation resolution now preserves redacted `resolver_metadata`
  from channel callbacks and typed email commands.
- Version metadata and built-in app versions moved to `0.16.0`.

### Safety

- Channels are delivery adapters only. They do not own intent, security policy,
  confirmation storage, memory, jobs, app routing, or execution authority.
- Telegram and email credentials are stored through Settings Secrets and are
  redacted from CLI output, traces, logs, and channel summaries.
- v0.16 adds no SMS, Discord, Slack, webhooks, IMAP IDLE, SMTP provider APIs,
  media downloads, attachments, remote document extraction, provider method
  execution, or proactive broadcast.

### Verification

- Milestone focused suites passed for channel settings/schema, durable event
  dedupe, identity resolution, Telegram transport/runtime/callbacks, email
  transport/runtime/commands, confirmation action metadata, and
  `mix allbert.channels`.
- Final v0.16 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.16-request-flow.md`.

## v0.15 - Minimal App Registration Contract

Status: released and tagged as `v0.15` on 2026-05-14. Version metadata is
`0.15.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- `AllbertAssist.App` lite behaviour for local workspace app identity,
  validation, optional child supervision, registered actions, skill paths, and
  static navigation surface entries.
- Supervised volatile `AllbertAssist.App.Registry`,
  `AllbertAssist.App.DynamicSupervisor`, and `AllbertAssist.App.Bootstrap`
  under `AllbertAssist.App.Supervisor`.
- Built-in `AllbertAssist.App.CoreApp` (`app_id: :allbert`) and transitional
  `AllbertAssist.App.StockSageStub` (`app_id: :stocksage`).
- Optional `app_id` on `AllbertAssist.Actions.Capability`, registry-backed
  stamping for app-registered actions, and
  `AllbertAssist.Actions.Registry.capabilities_for_app/1`.
- Read-only registered actions `list_apps` and `show_app`.
- `mix allbert.apps list`, `mix allbert.apps show APP_ID`, and
  `mix allbert.apps validate MODULE`.
- App-contributed skill paths in `AllbertAssist.Skills.Registry` at
  precedence 3, after project roots and before user roots.

### Changed

- `AllbertAssist.Session.AppId` now validates active app ids through
  `AllbertAssist.App.Registry.normalize_app_id/1` instead of the v0.14 static
  allowlist.
- `AllbertAssist.Intent.Decision` treats unknown candidate `active_app` values
  as diagnostics-only fallbacks while preserving known session context.
- App id normalization avoids dynamic atom creation from operator, channel, or
  model input.

### Safety

- App registration is contract data, not authority. App ids, skill paths,
  navigation surfaces, and capability tags do not grant permissions.
- Registered app actions still execute only through
  `AllbertAssist.Actions.Runner.run/3`, Security Central, confirmation
  workflow, redaction, traces, and audits.
- v0.15 adds no `AllbertAssist.Surface` DSL, dynamic route loading, workspace
  shell, canvas state, app-scoped jobs, app-scoped permission grants, hosted
  accounts, external UI protocol adapters, or app generator.

### Verification

- Milestone focused suites passed for app behaviour/validation, registry
  supervision, capability tagging, decision validation, active-app session
  continuity, app actions, `mix allbert.apps`, app skill-path discovery, child
  failure diagnostics, and restart recovery.
- Final v0.15 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.15-request-flow.md`.

## v0.14 - Session Scratchpad And Active App Context

Status: released and tagged as `v0.14` on 2026-05-14. Version metadata is
`0.14.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- Supervised `AllbertAssist.Session.Scratchpad` GenServer owning a protected
  ETS table keyed by `{user_id, session_id}`.
- `AllbertAssist.Session` facade for normalized `get`, `put`,
  `set_active_app`, `clear_active_app`, `merge_working_memory`, `clear`,
  `list`, `touch`, and `sweep_expired` operations.
- Settings Central key `sessions.scratchpad_ttl_minutes` with default `30`
  and validation range `[1, 1440]`.
- Static v0.14 `AllbertAssist.Session.AppId` allowlist for nil/general,
  `:allbert`, and `:stocksage` active-app context.
- Registered actions `set_active_app`, `clear_active_app`, and
  `show_session_scratchpad` through the shared action runner.
- `mix allbert.sessions` list/show/set-active-app/clear-active-app/clear/sweep
  commands.
- `mix allbert.ask --session SESSION_ID`.

### Changed

- Runtime requests with a `session_id` read scratchpad context once per turn,
  touch live entries, and propagate `active_app` to input signals,
  intent-agent request maps, response signals, response maps, traces,
  assistant/user message metadata, and assistant action logs.
- `AllbertAssist.Intent.Decision` validates `active_app` through the v0.14
  allowlist and rejects unknown model/agent active-app output.
- Scheduled runtime-prompt job run logs now preserve inherited response
  `active_app` context.

### Safety

- Scratchpad state is volatile ETS context only. It is not durable memory,
  auth, hosted sessions, app registration, app routing, or a security boundary.
- Raw `working_memory` values stay out of CLI output, registered action
  results, signals, traces, logs, response payloads, and persisted action logs.
- v0.14 adds no workspace UI, canvas state, browser/crawler behavior,
  semantic/vector retrieval, hosted accounts, new permission classes, new
  confirmation semantics, or new execution primitives.

### Verification

- Milestone focused suites passed for scratchpad API/TTL/restart behavior,
  Settings validation, AppId normalization, registered actions, sessions CLI,
  runtime propagation, Decision validation, ask CLI, job inheritance, and
  observability redaction.
- Final v0.14 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.14-request-flow.md`.

## v0.13 - Scheduled Jobs

Status: released and tagged as `v0.13` on 2026-05-14. Version metadata is
`0.13.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- SQLite scheduled jobs and run records through `AllbertAssist.Jobs`,
  `scheduled_jobs`, and `scheduled_job_runs`, with opaque `job_...` and
  `run_...` ids.
- Schedule normalization and next-due calculation for manual, daily, weekly,
  and supported five-field cron-like schedules.
- Supervised local `AllbertAssist.Jobs.Scheduler` with durable due-job polling,
  schedule-policy pause support, job lifecycle signals, and stale running-run
  cleanup using `scheduler_restarted`.
- `AllbertAssist.Jobs.Runner` for manual and scheduler runs through existing
  runtime/action boundaries.
- `mix allbert.jobs` for list/show/runs/create/pause/resume/run plus explicit
  CLI templates.
- Built-in templates `daily-brief`, `registry-health`, and `trace-summary`;
  templates instantiate ordinary job rows and are not seeded.
- Read-only registered actions `registry_health` and `trace_summary`.
- Thin `/jobs` LiveView inspection for jobs, recent runs, confirmation ids,
  and pause/resume/manual-run controls.

### Changed

- `jobs.timezone`, `jobs.default_state`, and `jobs.schedule_policy` are now
  writable Settings Central keys.
- Confirmation origins now preserve scheduled-job `job_id`, `run_id`,
  `user_id`, `operator_id`, `thread_id`, `session_id`, and `app_id` when
  confirmation-producing actions run from jobs.
- Job run summaries are redacted and JSON-safe before persistence.

### Safety

- Jobs do not add new execution primitives. Runtime prompt jobs call
  `AllbertAssist.Runtime.submit_user_input/1`; registered action jobs call
  `AllbertAssist.Actions.Runner.run/3`.
- Confirmation-required job work stops at the existing durable confirmation
  workflow and blocks automatic reruns without creating a job-specific approval
  queue.
- v0.13 adds no hosted accounts, roles, distributed scheduling, remote workers,
  archive/delete workflow, app-specific routing, session scratchpad semantics,
  or automatic markdown-memory promotion.

### Post-Validation Fixes

- Blocked jobs can no longer be resumed while their referenced confirmation is
  still pending. Once the confirmation is resolved, resume clears
  `blocked_confirmation_id`, reactivates the job, and recomputes `next_due_at`.
- Manual job runs now reject blocked jobs before creating a run record, with
  CLI and `/jobs` LiveView output pointing to `mix allbert.confirmations show`.
- The scheduled job unique constraint name now matches the migration index.
- Added regression coverage for blocked resume/run behavior, CLI and LiveView
  blocked-state handoff, `new_thread_per_run`, deleted origin-thread runtime
  failures, and cross-midnight cron schedules.

### Verification

- Milestone focused suites passed for job schema/context behavior, schedule
  parsing, manual runner behavior, supervised scheduler due polling, restart
  cleanup, CLI commands/templates, confirmation origin metadata, and LiveView
  inspection.
- Final v0.13 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.13-request-flow.md`.

## v0.12 - Local Workspace Identity And Conversation History

Status: released and tagged as `v0.12` on 2026-05-13. Version metadata is
`0.12.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- SQLite conversation history through `AllbertAssist.Conversations`,
  `conversation_threads`, and `conversation_messages`, with opaque `thr_...`
  and `msg_...` ids.
- Canonical local string `user_id`, preserving `operator_id` as a compatibility
  alias and defaulting omitted identity to `"local"`.
- Runtime thread selection for explicit `thread_id`, recent general thread,
  and `new_thread` requests.
- User messages are persisted before the agent runs; assistant messages are
  persisted after response and trace metadata are known.
- Bounded recent thread context, initially the last 12 prior messages, is
  passed to the intent agent as structured `thread_context`.
- `mix allbert.ask` now accepts `--user`, `--thread`, and `--new-thread`, while
  preserving `--operator`.
- `mix allbert.threads` lists user-scoped threads and shows ordered messages.

### Changed

- Runtime responses, input/response signals, traces, v0.11 intent decisions,
  confirmation origins, and persisted assistant action logs carry `user_id`
  and `thread_id`.
- CLI ask output renders `User:` and `Thread:` alongside status, message,
  signal, trace, Approval Handoff, diagnostics, and actions.
- v0.11 confirmation-required turns now persist pending assistant history with
  decision, resource access, Approval Handoff, diagnostics, and confirmation
  metadata.

### Safety

- v0.12 adds no hosted accounts, auth, roles, teams, app routing, session
  scratchpad, semantic retrieval, vector search, LiveView thread sidebar, or
  markdown-memory promotion.
- User isolation is local context and UX scoping, not hosted authorization.
- Conversation history is SQLite-only and distinct from markdown long-term
  memory. Ordinary conversation turns do not create markdown memory entries;
  explicit memory actions and explicit trace recording keep their existing
  behavior.
- v0.11 operation-scoped approvals, remembered grant matching, Security
  Central, Settings Central, confirmation resolution, shell/package/network
  policy, redaction, traces, and audits remain authoritative.

### Verification

- Milestone focused suites passed for conversation schema/context behavior,
  runtime identity normalization, thread selection, message persistence,
  bounded thread context, CLI ask/thread surfaces, cross-user isolation,
  trace/signal metadata, confirmation-origin metadata, and v0.11 Approval
  Handoff persistence.
- Final v0.12 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.12-request-flow.md`.

## v0.11 - Execution-Aware Intent, Resource Access, And Approval Handoff

Status: released and tagged as `v0.11` on 2026-05-13. Version metadata is
`0.11.0`; the operator manual verification matrix is ready for acceptance
checks.

### Added

- `AllbertAssist.Intent.Decision`, `AllbertAssist.Intent.ResourceAccess`, and
  `AllbertAssist.Intent.ApprovalHandoff` as inert contracts for selected
  intent, skills/actions, permission, confirmation, execution mode, URI-backed
  resource posture, alternatives, diagnostics, traces, and reserved
  `user_id`/`thread_id`/`session_id`/`active_app` context.
- Runtime responses, signals, and markdown traces now carry decision,
  resource-access, diagnostics, and Approval Handoff metadata.
- CLI and LiveView approval surfaces render the shared Approval Handoff for
  pending confirmations, including confirmation id, target action, operation
  class, scope, limits, downstream consumer, remember-scope choices, and
  approve/deny/details controls.
- URL summary prompts now create pending `external_network_request`
  confirmations with `summarize_url` resource refs before any fetch. Approved
  fetches report `summarizer_unavailable` until a summarizer action exists.
- Remote document inspection prompts now create pending
  `external_network_request` confirmations with `inspect_document` resource refs
  before any fetch. Approved fetches report `extractor_unavailable` until a
  registered extractor exists.
- Generic local file inspection prompts now return inert `file://...`
  `read_local_path` posture and an explicit no-shell-fallback unavailable state.
- Direct skill URL import, local skill directory import, package planning,
  shell execution, trusted skill scripts, online skill sources, and unsupported
  MCP/agent schemes are covered as operation-scoped URI consumers in the
  decision/handoff path.

### Changed

- The v0.10 URI-first resource substrate is now consumed by execution-aware
  intent instead of only by individual actions.
- Approval Handoff is shared channel metadata; CLI and web surfaces still resolve
  through `approve_confirmation` and `deny_confirmation` rather than mutating
  confirmation records or invoking adapters directly.
- URL/document consumer approvals are operation-scoped. `summarize_url` and
  `inspect_document` grants do not authorize `import_skill`,
  `external_service_request`, package install, activation, or script execution.
- README, roadmap, v0.11 plan, v0.11 request flow, and v0.12/v0.13/v0.16
  handoff docs now describe v0.11 as the current implemented base for the next
  milestones.

### Safety

- v0.11 adds no new browser, crawler, MCP, agent, package, shell, skill script,
  generic local file, or network primitive.
- Intent decisions are descriptive and validated before dispatch; they do not
  execute or authorize work by themselves.
- Approved URL/document fetches still run only through the v0.10 confirmed Req
  adapter, Settings Central policy, Security Central, confirmation re-check,
  redaction, trace, and audit boundaries.
- Missing summarizer, extractor, or bounded local reader capabilities are shown
  as unavailable instead of falling back to shell commands, ad hoc file reads,
  browser automation, or model-generated scripts.

### Verification

- Milestone focused suites passed for intent decision validation, Approval
  Handoff data, CLI and LiveView rendering, URL summary/document/local-file
  consumers, external request operation-scoped grants, direct/local skill import,
  package resource posture, resource refs, remembered grants, and unsupported
  MCP/agent flows.
- Final v0.11 closeout gates passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- Manual verification steps live in `docs/plans/v0.11-request-flow.md`.

## v0.10 - External Capability Adapters

Status: implemented through M14 after the reopened v0.10 M6-M9 sequence. The
original M5 release-readiness gate was reopened for online skill approval
clarity/search fixes and Resource Access Security Posture planning; M9 closed
the release-readiness refresh. A later zoom-out release audit reopened v0.10
for M10-M14 closeout milestones before release. M10 landed
resource identity hardening; M11 has landed remembered-grant operator
UX/application for existing v0.10 actions. M12 has landed URI-first
`resource_uri` resource/grant authority through
`AllbertAssist.Resources.ResourceURI`. M13 has landed direct/local skill
import consumers on that URI substrate. M14 has landed final unsupported UX
and v0.11 handoff readiness. v0.10 was released and tagged as `v0.10` on
2026-05-04.

### Added

- Security Central and Settings Central scaffolding for external services,
  package installs, and online skill import.
- Confirmed `Req` external service adapter for allowlisted
  `external_network_request` approvals.
- Package install planning and confirmed npm execution through
  `plan_package_install`, `run_package_install`, `approve_confirmation`, and
  `mix allbert.packages`.
- Package install audit records under
  `<ALLBERT_HOME>/execution/package-installs/audit`.
- Confirmed online skill search, detail, audit, and disabled import through
  `search_online_skills`, `show_online_skill`, `audit_online_skill`,
  `import_online_skill`, and `mix allbert.skills ...-online`.
- Online skill search uses the current skills.sh JSON search endpoint
  `https://skills.sh/api/search` from the configured source API base.
- Source manifests for imported online skills under
  `<ALLBERT_HOME>/cache/skills/_sources`.
- `/settings`, `mix allbert.confirmations`, confirmation audits, and markdown
  traces now render v0.10 external request, package install, and online skill
  request/result metadata from the same durable records.
- Approved online skill source failures resolve as confirmation `approved`
  with `target_status=failed` and a rendered failure reason, rather than
  looking like the operator denied the request.
- Security status marks the v0.10 external adapters and imports boundary
  implemented and shows redacted policy summaries for external services,
  package installs, and online skill import.
- Shared resource reference metadata is emitted by shell command summaries,
  trusted skill script summaries, external request summaries, package install
  summaries, and online skill source actions. The metadata is plain data with
  origin kind, canonical id, operation class, access mode, scope, limits,
  downstream consumer, redaction, digest, and metadata fields; it does not
  approve, grant, fetch, import, install, summarize, or execute by itself.
- Remembered resource grants are stored under Settings Central key
  `resource_grants.remembered`. Grants are generic resource approval memory:
  canonical `resource_uri`, origin/scope metadata, operation class, access
  mode, downstream consumer, channels, expiry, revocation, audit path, and
  reason.
  `AllbertAssist.Resources.Grants.find_applicable/2` requires the caller to
  pass the current action permission for Security Central policy re-check.
- External request summaries now separate canonical URL authority from
  redacted display URL output. Remembered grant matching uses canonical URL
  scope; operator-facing resource metadata renders the redacted display URL
  when available.
- Resource grant matching resolves existing intermediate local symlink
  components before subtree comparison and rejects source-profile grants when
  same-id source endpoint fingerprints drift.
- Registered resource grant actions now list, show, revoke, and remember
  grants through `list_resource_grants`, `show_resource_grant`,
  `revoke_resource_grant`, and `remember_resource_grant`.
- `mix allbert.resources grants list/show/revoke` provides operator CLI
  controls for remembered resource grants.
- `mix allbert.confirmations approve` supports explicit remembered-grant
  options: `--remember`, `--resource-index`, `--remember-all`, and
  `--grant-expires-at`.
- `/settings` now lists active/revoked remembered resource grants, revokes
  them through the registered action boundary, and exposes
  approve-with-remember controls for pending resource-backed confirmations.
- Existing v0.10 actions apply matching remembered grants before creating new
  confirmations for `external_network_request`, online skill
  search/detail/audit/import, and `run_package_install`. Grant reuse is
  operation-scoped and requires all current action resource refs to match.
- Registered action capability metadata now marks which confirmation targets
  are resumable, and `approve_confirmation` checks that metadata before
  attempting target execution.
- ADR 0013 now records URI-first resource identity and permission matching.
  Refs and remembered grants carry canonical `resource_uri` authority while
  `origin_kind`, `canonical_id`, and scopes remain derived/descriptive
  metadata. Pre-M12 grant records without `resource_uri` are not matched
  through a legacy compatibility layer.
- Direct skill URL import is available through `import_remote_skill` and
  `mix allbert.skills import-url URL`. It creates confirmation before fetch,
  uses `https://... + import_skill` resource refs, requires
  `:online_skill_import` plus external service policy, supports remembered
  grants for the same operation boundary, and writes only disabled/untrusted
  imported candidates under `<ALLBERT_HOME>/cache/skills`.
- Local skill directory import is available through `import_local_skill` and
  `mix allbert.skills import-local PATH`. It creates confirmation before
  reading imported content, uses `file://... + import_local_skill` resource
  refs, denies unsafe paths/symlinks during import, and writes only
  disabled/untrusted imported candidates under `<ALLBERT_HOME>/cache/skills`.
- Unsupported v0.11-owned resource workflows now route to the inert
  `unsupported_resource_workflow` action. CLI, LiveView, and the runtime give
  the same no-fetch/no-read/no-execute explanation for URL summarization,
  document inspection/extraction, MCP resource/tool calls, `agent://` or
  `agent+https://` delegation, broad browsing/crawling/research, and future
  channel-native approval handoff.
- Version metadata bumped to `0.10.0`.

### Changed

- Planning docs now frame v0.10 as the first Resource Access Security Posture
  substrate, not a skills-only or network-only release. Online skill
  search/import is one remote-source consumer; M13 direct/local skill import
  is another. Future URL summarization, document inspection, and other
  local/remote consumers must use the same operation-scoped approval, trace,
  and audit posture.
- README now reads as a project overview and documentation index rather than a
  testing plan. First-run operator guidance lives in
  `docs/operator/onboarding.md`; the v0.10 smoke matrix remains in
  `docs/plans/v0.10-request-flow.md`.
- The reopened v0.10 plan has implemented the shared resource reference
  contract and remembered grant contract before release. v0.11 owns
  execution-aware Approval Handoff UX for consumers such as `summarize_url`,
  `inspect_document`, `import_skill`, and `import_local_skill`.
- M9 refreshed release docs, roadmap/future handoffs, operator onboarding
  pointers, and the v0.10 smoke matrix so operators can test the final M6-M8
  resource posture without treating skills.sh as the platform model.
- M10 resolved the resource identity and resume hardening debt discovered
  after M9: canonical resource identity is separated from redacted display
  data, local path scope matching handles intermediate symlink escape, source
  profile drift invalidates grants, and confirmation resume eligibility lives
  in registered action capability metadata.
- M11 turns remembered grants from tested substrate into operator behavior:
  list/show/revoke, approve-with-remember, `/settings` controls, and reuse for
  existing v0.10 network/source/package flows.
- M12 turns resource identity URI-first in code: `Resources.Ref` emits
  `resource_uri`, `Resources.Grants` stores and matches on `resource_uri`
  authority, Settings Central validates the required field, `mix
  allbert.resources` prints it, and inert `mcp://`, `agent://`, and
  `agent+https://` refs are representable without execution authority.
- M13 adds direct skill URL import and local skill directory import on the
  URI-first substrate. These are skill-import consumers of the generic resource
  posture, not a marketplace-only path. M14 owns final unsupported
  URL/document/MCP/agent messaging and v0.11 handoff readiness.
- M14 closes v0.10 by routing v0.11-owned resource workflows to explicit
  unsupported/deferred UX rather than creating partial `external_network`
  confirmations. v0.11 consumes this as the baseline for execution-aware
  intent and channel-native Approval Handoff.

### Safety

- npm package installs require exact package specs, an allowed target root,
  durable confirmation, explicit argv, disabled lifecycle scripts,
  `--allow-git=none`, timeout/output caps, and package audit.
- URL, tarball, git, file/path, global, shell-metacharacter, and unpinned
  package specs are denied by default.
- pip remains preview-only and cannot execute in v0.10 without future strict
  hash, binary, pinned requirement, and target policy.
- Online skill search/detail/audit are confirmed external reads. Import creates
  a confirmation before fetching or writing, stores only under Allbert cache,
  and leaves imported skills disabled, untrusted, and non-executable.
- Direct HTTPS skill URL import and local skill directory import follow the
  same disabled/untrusted import state. Neither path trusts, enables,
  activates, runs scripts, installs dependencies, loads Elixir modules, or
  executes package managers.
- Operator approval is recorded separately from target execution success:
  source HTTP/transport failures after approval are failed target outcomes, not
  Security Central or operator denials.
- v0.10 does not implement arbitrary URL/document summarization, MCP
  execution, `agent://` delegation, a browser, or a crawler. Those consumer UX
  flows now return explicit unsupported/deferred responses and still need the
  v0.11 intent and Approval Handoff contract over the v0.10 URI resource
  posture.

### Verification

- Focused M5 suites passed for `mix allbert.external`, `mix allbert.packages`,
  `mix allbert.skills`, `mix allbert.confirmations`, `/settings`, runtime
  external request tracing, trace action metadata, and Security Central status.
- Final gates for v0.10 M5 passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- `mix precommit` passed with 248 core tests and 17 web tests.
- M9 reran the focused post-M5 online skill regressions, M7 resource reference
  tests, M8 remembered grant tests, and final release gates before restoring
  tag-readiness wording.
- M9 `mix precommit` passed with 270 core tests and 17 web tests.
- M7 focused resource reference tests pass for shell cwd/path operands, skill
  script resources, external request refs, online skill import refs, package
  install refs, local-vs-remote skill import grant separation, closed operation
  vocabulary, and resource metadata rendering.
- M7 adjacent suites pass for online skill actions, execution/request/package
  summary metadata, confirmation CLI rendering, trace rendering, and
  `/settings` confirmation display. M7 cleanup gates pass:
  `mix compile --warnings-as-errors`, `mix format --check-formatted`,
  `mix credo --strict`, and `git diff --check`.
- M8 focused grant tests pass for exact local files, local directory subtrees,
  symlink/traversal escape denial, exact URLs, URL prefixes, redirect escape
  denial, source profiles, operation mismatch, local-vs-remote import
  separation, expired/revoked grants, explicit permission policy drift, and
  remember-option handoff data.
- M8 cleanup gates pass: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, and
  `git diff --check`.
- M10 focused tests pass for canonical-vs-display URL refs, redacted URL grant
  authority denial, intermediate symlink directory escape denial,
  source-profile drift rejection, registry-driven resumable action metadata,
  and historical `adapter_unavailable` behavior.
- M11 focused tests pass for registered grant actions, confirmation
  approve-with-remember, CLI grant controls, `/settings` grant list/revoke,
  existing external request/online skill/package-install grant reuse, and the
  package all-refs rule that prevents target-root grants from authorizing
  package registry drift.
- M13 focused tests pass for direct remote URL import confirmation/approval,
  denied-no-fetch behavior, operation-scoped grant separation, local directory
  import confirmation/approval, symlink escape denial, existing online skill
  regressions, Mix task output, resource grants, and registry metadata.
- M14 focused tests pass for unsupported URL summarization, document/MCP/agent
  handoff routing, CLI ask output, LiveView rendering, registry metadata, plus
  the existing external request, online skill, package install, direct/local
  skill import, confirmations, resource refs, resource grants, resource CLI,
  skill CLI, and `/settings` suites.
- Operator/user testing should start with `docs/operator/onboarding.md` and
  use the disposable v0.10 smoke flow in `docs/plans/v0.10-request-flow.md` or
  `docs/plans/v0.10-plan.md` before accepting and tagging `v0.10`.

## v0.09 - Skill Script Runner

Status: accepted for operator/user testing. Release tag is `v0.09`.

### Added

- `run_skill_script` as the only registered action for trusted Agent Skill
  script resources.
- Security Central `:skill_script_execute` permission, high risk tier, and
  confirmation safety floor.
- Settings Central `execution.skill_scripts.*` policy and interpreter-profile
  validation surface.
- Resource-gated `SkillScriptSpec` resolver for trusted/enabled skills,
  validated capability contracts, exact `AllbertAssist.Skills.Resource`
  inventory matching, SHA-256 digest re-checks, direct executable launch mode,
  cwd/path/env/timeout/output validation, and redacted summaries.
- Durable pending/resolved confirmation flow for skill scripts, including
  policy re-check and digest re-check on approval.
- Bounded skill script runner with explicit executable plus argv, per-run cwd
  handling, timeout, output caps, redacted output previews, and script audit
  records under `<ALLBERT_HOME>/execution/audit`.
- `mix allbert.skills run SKILL SCRIPT [--cwd PATH] [--timeout MS]
  [--max-output-bytes BYTES] -- [ARGS...]`.
- CLI and `/settings` rendering for pending/resolved skill script metadata:
  skill, script path, digest, cwd, timeout, output cap, result, exit status,
  timeout/truncation flags, and redacted output preview.
- Version metadata bumped to `0.9.0`.

### Changed

- Confirmation approval now resumes `run_skill_script` targets through the
  shared action runner, not direct store mutation or channel-owned execution.
- Security status marks the v0.09 skill script runner boundary as implemented.
- `activate_skill` remains progressive-disclosure-only; reading or activating a
  skill still never runs bundled scripts.
- v0.10 planning now consumes a real trusted script runner while retaining
  package-install, external-network, online-import, and deeper sandbox work as
  separate future capabilities.

### Safety

- v0.09 runs only trusted, enabled, inventoried skill script resources after
  durable operator confirmation.
- Script paths are resource identifiers, not arbitrary filesystem authority:
  absolute paths, traversal, hidden paths, missing resources, non-script
  resources, non-executable scripts, digest drift, out-of-root cwd/path-like
  args, disallowed env keys, and limit violations are denied before execution.
- v0.09 does not add package installs, external service calls, online skill
  import auto-enable, generic scripting engines, runtime Elixir module loading,
  persistent background scripts, or Docker/Podman/container/microVM isolation.
- Level 1 host execution is still not a hostile-code sandbox and does not
  claim network isolation.

### Verification

- Milestone focused suites passed for M1 through M5.
- Release-readiness gates for M5 passed: `mix compile --warnings-as-errors`,
  `mix format --check-formatted`, `mix credo --strict`, `mix dialyzer`,
  `mix precommit`, and `git diff --check`.
- `mix precommit` passed with 206 core tests and 16 web tests.
- Operator/user testing should use the disposable `ALLBERT_HOME` and temporary
  workspace smoke in `docs/operator/onboarding.md` or `docs/plans/v0.09-plan.md`.
- Disposable CLI smoke passed for validate, run, list, approve, and
  list-resolved against a temporary trusted skill and workspace.

## v0.07 - Confirmation Workflow

Status: released and tagged as `v0.07` on 2026-05-02.

### Added

- Durable confirmation requests under `<ALLBERT_HOME>/confirmations`, with
  pending, resolved, and markdown audit records.
- Registered confirmation actions for list, show, approve, deny, and expire,
  plus `mix allbert.confirmations`.
- Settings Central confirmation policy for TTL, denial reasons, approval
  surfaces, and cross-channel approval.
- `external_network_request` pending confirmation creation when Security
  Central returns `:needs_confirmation`.
- `/settings` Confirmation Requests surface for the same shared queue used by
  CLI.
- First-class confirmation metadata in runtime traces and richer markdown audit
  entries.

### Changed

- Approval now re-reads the pending record, enforces approval-surface and
  cross-channel settings, re-checks Security Central with confirmation context,
  and records resolver channel metadata.
- Approved external-network requests resolve as `adapter_unavailable` in v0.07
  because no real network adapter exists yet.
- Operator-facing CLI and LiveView output explains `adapter_unavailable` as
  approved, recorded, and not executed because the v0.07 target has no adapter;
  external network execution is planned for v0.10.
- If target policy changes to denied before approval, the request resolves as
  `denied` and target work is not invoked.

### Safety

- v0.07 adds no shell execution, skill script execution, package installation,
  online import, or real external network calls.
- Approval is an operator decision for one pending request, not a generic
  permission grant, and it does not bypass Security Central safety floors.
- CLI and LiveView share one durable, channel-aware queue; neither surface owns
  storage, policy, or target resumption.

### Verification

- Focused milestone suites passed for M1 through M6.
- Final gates passed: `mix compile --warnings-as-errors`, `mix format
  --check-formatted`, `mix credo --strict`, `mix dialyzer`, `mix precommit`,
  and `git diff --check`.
- `mix precommit` passed with 169 core tests and 14 web tests.
- Operator smoke used a disposable `ALLBERT_HOME` to create an external-network
  pending confirmation, inspect it with CLI, approve it to
  `adapter_unavailable`, list resolved records, and verify traces/audits.

## v0.08 - Local Execution Sandbox And Shell Adapter

Status: released and tagged as `v0.08` on 2026-05-02.

### Implemented So Far

- Level 1 local policy sandboxing for confirmed shell command execution.
- `run_shell_command` as the only registered command execution action.
- Settings Central `execution.local.*` policy for allowed roots, allowed
  commands, operator command profiles, path operands, blocked args, env
  allowlist, timeout, output caps, and confirmation.
- Security Central `:command_execute` decisions remain denied by default but can
  be capped to `:needs_confirmation` when the operator explicitly allows
  command execution.
- Durable v0.07 confirmation resume for approved command requests, with
  `target_resumed?: true` only after policy re-check and local runner success.
- CLI and `/settings` output over the same action/confirmation boundary.
- `mix allbert.exec` for deterministic local command-spec testing.
- `mix allbert.ask` prompt routing for command-shaped requests.
- Trace and audit metadata for sandbox level, executable/argv summary, cwd,
  env policy, timeout, output size, exit status, denial reason, and output
  preview.
- Execution markdown audit under `<ALLBERT_HOME>/execution/audit`.
- Version metadata bumped to `0.8.0`.

### Safety

- No autonomous shell execution.
- No unconfirmed command execution.
- No shell strings, PTY sessions, command chaining, redirection, inline
  interpreter eval, background processes, or long-running daemon management.
- No unprofiled mutating/destructive local commands and no out-of-root path
  operand access.
- No skill script execution; v0.09 owns that.
- No external network execution or package installs; v0.10 owns those.
- No Docker, Podman, Mac/Linux container, remote, or microVM backend in v0.08.
  Future deeper sandboxing is tracked in `docs/plans/future-features.md`.

### v0.09 Handoff

- v0.09 should add trusted, resource-gated skill script execution through
  `run_skill_script`, not a generic scripting engine.
- v0.09 must preserve the v0.08 Level 1 host execution caveat: trusted scripts
  can run with policy controls, but this is not container, remote, microVM, or
  network isolation.

## v0.06 - Action-Backed Allbert Skills

Status: released on 2026-05-02.

### Added

- Canonical action capability metadata through
  `AllbertAssist.Actions.Capability` and `AllbertAssist.Actions.Registry`.
- Executable contract validation in
  `AllbertAssist.Skills.CapabilityContract.validate/2` for registered action
  names, skill-backed eligibility, known permission classes, confirmation
  policy, and single-action v0.06 execution shape.
- Skill registry/list/read/activation output that reports contract validation
  status, diagnostics, and execution eligibility while keeping invalid
  contracts inspectable.
- `AllbertAssist.Skills.ActionPlan` for validating selected built-in
  skill/action pairs before invoking the shared action runner.
- Runner, lifecycle signal, trace, and Security Central metadata for selected
  skill, validated contract, selected action capability, permission decision,
  risk, policy, and outcome.
- Local skill helper actions `validate_skill` and `create_skill`, plus
  `mix allbert.skills validate PATH` and `mix allbert.skills create ...`.
- `:skill_write` permission with Settings Central key
  `permissions.skill_write`, default `allowed`, safety floor `allowed`, and
  medium risk tier.

### Changed

- Deterministic built-in routes now select the matching trusted built-in skill,
  validate its contract, and then execute through
  `AllbertAssist.Actions.Runner.run/3`.
- `direct-answer`, `append-memory`, `read-recent-memory`, `list-skills`,
  `read-skill`, `plan-shell-command`, and `external-network-request` are the
  initial action-backed skill surface.
- `activate_skill` remains progressive-disclosure-only and does not execute
  the activated skill's declared action.
- `validate_skill` and `create_skill` are registered helper actions but are
  intentionally excluded from the intent-agent tool surface.
- v0.07 planning now consumes v0.06 selected skill/action metadata and the
  `:skill_write` policy surface for confirmation workflow design.

### Safety

- v0.06 adds no shell execution, skill script execution, package installation,
  external network adapter calls, online import, module loading, autonomous
  skill creation, or confirmation queue.
- Skill metadata, YAML, markdown, `allowed-tools`, and bundled resources never
  grant permission or execute by themselves.
- Local skill scaffolding writes only standard `SKILL.md` wrappers for already
  skill-backed registered actions with matching known permission classes.
- Structurally valid local skills remain `execution_eligible?: false` until
  trusted and enabled through registry policy.

### Verification

- Milestone focused suites passed for M1 through M6.
- Closeout `rg` checks found no module loading, no direct intent action
  `run/2` calls, no private Security Central or Settings Central calls from
  operator surfaces, and only inert safety-text matches for execution-related
  phrases.
- Operator smoke passed in a disposable `ALLBERT_HOME`, covering skill list,
  memory write/read, skill read/activation, denied shell planning,
  external-network confirmation, local skill validation/scaffolding, security
  status, and trace metadata.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix
  credo --strict`, `mix dialyzer`, and `mix precommit` passed.
- `mix precommit` passed with 152 core tests and 12 web tests.

## v0.05 - Security Central Foundation

Status: released on 2026-05-02.

### Added

- `AllbertAssist.Security` as the shared Security Central facade for
  authorization and read-only operator status.
- Security modules for normalized context, policy resolution, canonical
  decisions, risk tiers, redaction, audit metadata, trust boundaries, and
  status summaries.
- Registered internal `security_status` action and `mix allbert.security
  status` for operator inspection.
- Settings Central permission keys for memory writes, command planning,
  command execution, external network requests, and settings writes.
- Security & Permissions section in `/settings`, with editable Settings
  Central permission defaults and read-only effective Security Central status.
- Compact `## Security Metadata` trace output for redacted decisions.

### Changed

- `AllbertAssist.Security.PermissionGate.authorize/2` now delegates to
  Security Central while preserving compatibility fields and helper behavior.
- `AllbertAssist.Actions.Runner.run/3` attaches selected action metadata and
  redacted permission decisions to runner metadata.
- Action lifecycle signals, trace rendering, and security status now use the
  central security redactor.
- v0.06 planning now consumes Security Central's decision shape, selected skill
  trust/provenance, known permission classes, and safety-floor capped policy.

### Safety

- v0.05 adds no new execution powers.
- Settings Central can tighten permission defaults, but built-in safety floors
  still deny or cap shell execution, skill scripts, package installs, external
  network execution, online skill imports, raw secret reads, unknown actions,
  and unknown permissions.
- Skill metadata, `allowed-tools`, and YAML declarations remain inert and never
  grant permission by themselves.
- Raw secrets are redacted from security status, traces, audits, runner
  metadata, signals, CLI, LiveView, logs, and tests.

### Verification

- Focused v0.05 integration suite passed with 85 core tests and 7 web tests.
- `mix compile --warnings-as-errors`, `mix format --check-formatted`, `mix
  credo --strict`, `mix dialyzer`, and `git diff --check` passed.
- `mix precommit` passed with 139 core tests and 12 web tests.

## v0.04 - Jido Runtime Convergence Refactor

Status: released on 2026-05-02.

### Added

- `AllbertAssist.Actions.Registry` as the canonical registered action list.
- `AllbertAssist.Actions.Runner.run/3` with action-requested/completed Jido
  lifecycle signals and runner metadata.
- `AllbertAssist.Signals` helpers with recursive redaction, including struct
  redaction for trace-turn signal params.
- Settings model-profile action `list_model_profiles`.
- Internal trace action `record_trace` so runtime trace writes are observable
  action work.

### Changed

- `IntentAgent` routes all selected actions through the shared runner.
- `mix allbert.settings` uses settings actions through the runner for list,
  get, explain, set, provider list, and provider key writes.
- `/settings` uses settings actions through the runner for settings, provider,
  model, and provider credential flows.
- Runtime trace persistence uses the internal `record_trace` action instead of
  calling `Trace.record_turn/1` directly.
- Trace files now include runner metadata for representative user-facing
  actions.

### Safety

- No shell, script, package install, external service, online import, or
  action-backed skill execution capability was added.
- Unknown action names and unregistered modules are denied by the runner.
- Provider keys remain accepted only through explicit CLI/LiveView credential
  flows and are redacted from output, action metadata, traces, logs, and tests.

### Verification

- Focused v0.04 gate passed with 62 core tests and 6 web tests.
- `mix precommit` passed with 120 core tests and 11 web tests.
- `mix dialyzer` passed.
- Operator smoke passed in a disposable `ALLBERT_HOME`, covering traced direct
  answer, skill listing, denied command planning, settings list/write, provider
  listing, and trace metadata inspection.

## v0.03 - Agent Skills Substrate

Status: released on 2026-05-02.

### Added

- Standard Agent Skills `SKILL.md` parsing, validation, diagnostics, and
  resource inventory for `scripts/`, `references/`, and `assets/`.
- Registry-backed skill discovery across built-in, project, user,
  interoperable, imported-cache, and configured scan scopes.
- Trust, enablement, duplicate-name handling, source metadata, aliases, and
  inert Allbert capability contracts for discovered skills.
- Built-in Agent Skill wrappers for the current safe action surface:
  `direct-answer`, `append-memory`, `read-recent-memory`, `list-skills`,
  `read-skill`, `plan-shell-command`, and `external-network-request`.
- Dedicated `activate_skill` action for progressive disclosure of trusted
  skill instructions, diagnostics, resource inventory, and safety boundaries.
- Runtime traces with selected skill metadata, source scope, trust state,
  diagnostics, and resource inventory.
- CLI and LiveView tests for registry-backed skill list, read, alias read, and
  activation behavior.

### Changed

- `list_skills` and `read_skill` now use the registry instead of the old static
  in-code declarations.
- Settings Central can validate and write v0.03 skill trust and scan settings:
  `skills.scan_paths`, `skills.trusted_project_roots`, `skills.enabled`,
  `skills.disabled`, and `skills.imported_cache_policy`.
- Documentation now treats v0.04 action-backed skills as the next milestone and
  v0.03 as the completed compatibility/importability substrate.

### Safety

- Skill declarations, Allbert metadata, `allowed-tools`, bundled scripts,
  package instructions, and external catalogs remain non-executable.
- Activation is read-only context loading; it does not run scripts, shell
  commands, network calls, package installs, or Jido actions.
- Permission checks remain at the action boundary.

### Verification

- `mix precommit` passed with 119 tests, 0 failures, and Credo no issues.
- CLI closeout covered list, read, activate, missing-skill activation, and trace
  metadata in a disposable `ALLBERT_HOME`.
- LiveView operator tests covered the same runtime activation path.

## v0.02 - Allbert Home, Settings Central, Secrets, And Operator Profile

Status: released on 2026-05-01.

### Added

- Canonical Allbert Home under `ALLBERT_HOME`, with `ALLBERT_HOME_DIR` as an
  accepted alias and default root `~/.allbert`.
- Settings Central with typed YAML settings, layered resolution, write
  validation, and append-only audit markdown.
- Encrypted local secret store for provider API keys, with redacted CLI,
  LiveView, trace, audit, log, and test surfaces.
- Provider and model profile settings, operator profile settings, trace
  defaults, skill trust placeholders, and future channel/job/memory namespaces.
- Runtime settings actions plus `mix allbert.settings` and the `/settings`
  LiveView.

### Changed

- Durable memory now defaults under `<ALLBERT_HOME>/memory`, while
  `ALLBERT_MEMORY_ROOT` remains available as a specific override.
- Settings and secrets use one operator-facing control plane instead of
  scattering mutable user configuration through application config.

### Safety

- Raw provider credentials are accepted only through stdin or an interactive
  prompt and are never printed back.
- Tests and operator smokes use temporary Allbert homes rather than writing to a
  real user's `~/.allbert`.

## v0.01 - First Local Assistant Loop

Status: released on 2026-05-01.

### Added

- Signal-first runtime boundary with `AllbertAssist.Runtime.submit_user_input/1`.
- Primary Jido AI agent module with deterministic v0.01 action routing.
- Explicit Jido actions for direct answers, markdown memory, skill inspection,
  shell-command planning, and external-network request recognition.
- Central permission gate with allowed, denied, and confirmation-required
  decisions.
- Markdown-first memory store with `notes`, `preferences`, `traces`, and
  `skills` categories.
- Low-risk personal preference heuristics for identity, communication style,
  timezone, and working preferences.
- Markdown trace recording with `ALLBERT_TRACE_ENABLED=true` or app config.
- CLI entrypoint: `mix allbert.ask`.
- Phoenix LiveView runtime demo at `/agent`.
- Planning docs, request-flow docs, roadmap, and ADRs for the v0.01
  architecture.

### Changed

- The app now uses the primary intent agent instead of the earlier sample agent
  path.
- User recall excludes trace entries by default so diagnostic traces do not
  crowd out notes or preferences.
- Dialyzer is part of the project check path with narrow ignores for known
  `Jido.AI.Agent` macro-generated warnings.

### Safety

- Shell command execution remains unavailable and returns `:denied`.
- External network access is recognized but not performed; it returns
  `:needs_confirmation`.
- Trace write failures are reported as diagnostics and do not crash the
  user-facing response.

### Verification

- `mix precommit` passes.
- `MIX_ENV=test mix check` passes, including Dialyzer with zero stale ignores.
- CLI demo covers memory write, memory recall, denied command planning, and
  trace path output.
