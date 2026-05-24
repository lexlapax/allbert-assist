# AGENTS.md

This repository is Allbert: an Elixir/OTP assistant runtime built with Phoenix
and Jido. Phoenix LiveView is one operator/channel interface, not the center of
the system. The center is a signal-driven runtime, Jido agents and actions,
Security Central, Settings Central, markdown-first memory, plugins, and
Allbert Home.

This file is intentionally compact because it is loaded into coding-agent
context often. Do not turn it into release history. Use the roadmap,
CHANGELOG, ADRs, and active plans as targeted references.

## Start Here

Before coding, read only the context needed for the task:

1. `DEVELOPMENT.md`
2. `docs/plans/roadmap.md`
3. The active milestone plan in `docs/plans/`
4. The matching request-flow document, when one exists
5. Relevant ADRs in `docs/adr/`
6. Targeted `CHANGELOG.md` entries when released-history context matters
7. Relevant code and tests before editing

For deeper subsystem routing, use
`docs/developer/agent-context-map.md`. Load only the relevant section.

## Document Authority

When documents conflict, use this order:

1. Current user request
2. Code and tests
3. Active milestone plan and request-flow document
4. ADRs
5. `docs/plans/roadmap.md`
6. `CHANGELOG.md` released-history notes
7. Historical plans

Flag conflicts instead of silently choosing stale historical guidance.

## Context Budget

- Keep context focused. Do not bulk-read historical plans or the whole
  changelog.
- Prefer the active plan, relevant ADRs, focused changelog entries, and local
  code over broad document sweeps.
- Load `docs/developer/agent-context-map.md` only when a task needs historical
  or subsystem-specific routing.
- Use `CHANGELOG.md` to understand what shipped, not as the primary source for
  current design authority.

## Subsystem Routing

Use these as starting points, then narrow further from the active task:

- Runtime, action runner, signals, Security Central, confirmations, or Resource
  Access: read relevant active plan/request-flow docs plus ADR 0006, ADR 0007,
  ADR 0008, ADR 0012, and targeted changelog entries.
- Local identity, conversation history, sessions, or users: read ADR 0014 and
  the active plan touching the area.
- Memory review, promotion, search, indexes, or memory intent candidates: read
  `docs/plans/v0.21-plan.md`, `docs/plans/v0.21-request-flow.md`, ADR 0014,
  ADR 0019, and `CHANGELOG.md` v0.21.
- Plugins, channel plugins, app registration, app surfaces, or generated app
  structure: read ADR 0015, ADR 0017, the active plan, and the developer app
  guide when relevant.
- Channels and external identity mapping: read ADR 0016, the active plan, and
  latest channel-related changelog entries.
- Intent ranking, active app routing, classifier hooks, intent traces, app
  intent descriptors, conversational app handoff, or clarification: read
  ADR 0019, ADR 0034, the active plan, and latest intent-related changelog
  entries.
- Objectives, objective steps, objective events, advisory providers, world
  models, capability inventory, or any multi-step / cross-turn work: read
  ADR 0021, `docs/plans/v0.24-plan.md`, `docs/plans/v0.24-request-flow.md`,
  and `docs/research/objective-runtime-research.md`. `objective_id` is never
  authority; advisory provider output is never authority; predictions about
  user behavior never short-circuit confirmation.
- Jido.Agent vs. plain GenServer substrate: read the "Jido.Agent vs.
  GenServer" section in `docs/plans/allbert-jido-vision.md`,
  `docs/plans/v0.23-plan.md`, and the substrate paragraph in
  `DEVELOPMENT.md`. Use Jido.Agent when state machines, lifecycle hooks,
  Skill composition, or successor agents are plausibly useful; use plain
  GenServer for stateful storage where Jido.Agent buys nothing. New
  state-bearing modules document their substrate choice in the module
  `@moduledoc`.
- StockSage work: read the active StockSage milestone plan, ADR 0018, ADR
  0017, ADR 0015, and targeted StockSage changelog entries. For Python
  bridge, `RunAnalysis`, or `:stocksage_analyze` work read ADR 0020,
  `docs/plans/v0.22-plan.md`, and `CHANGELOG.md` v0.22; bridge code is
  plugin-owned (under `./plugins/stocksage/`), and the
  `:stocksage_analyze` safety floor is `:needs_confirmation` and cannot
  be lowered by settings. For native financial specialist agents read ADR
  0022 plus `docs/plans/v0.25-plan.md` and
  `docs/plans/v0.25-request-flow.md`; they are reusable delegate agents under
  the objective runtime, not a one-for-one Python TradingAgents graph clone.
  Python bridge calls after v0.25 are explicit comparison/reference runs only,
  never automatic fallback or a persistent default.
- Workspace shell, ephemeral UI, canvas, offline editing, Fragments, or app
  surfaces: read ADR 0015, ADR 0023, `docs/plans/v0.26-plan.md`, and
  `docs/plans/v0.26-request-flow.md`.

## Non-Negotiables

- Never include AI-tool attribution in git commits, commit messages, PR text,
  release notes, or generated docs. Do not add Claude, Codex, Gemini,
  opencode, Cursor, Antigravity, Pi, or similar generated-by/co-authored-by
  footers. This project follows strict human supervision during planning,
  architecture, and development; attribution belongs to the human project
  authors, not AI coding tools.
- Preserve user data. Do not delete or rewrite memory, traces, settings,
  secrets, databases, skill folders, or user-created files unless explicitly
  asked.
- Keep code warning-free: no compiler warnings, HEEx/parser warnings, unused
  aliases/imports, lexical tracker warnings, formatter drift, Credo findings,
  Dialyzer warnings, or focused-test failures at handoff.
- Use Context7 MCP for fresh docs whenever implementation depends on a
  library, framework, SDK, API, CLI, cloud service, or provider. If Context7 is
  unavailable, use official docs or source and say so.
- All user/operator-supplied configuration belongs in Settings Central.
- All durable local runtime data should derive from Allbert Home:
  `ALLBERT_HOME`, alias `ALLBERT_HOME_DIR`, default `~/.allbert`.
- Tests and CI must use a temporary Allbert home or temp-specific roots; never
  write to a real user's `~/.allbert`.
- User-supplied secrets, including API keys, must be encrypted at rest and
  redacted in CLI output, LiveView, traces, audits, logs, and tests.
- Runtime-facing, effectful, security-relevant, or observable domain behavior
  belongs behind signals, internal agents or runtime routers, and registered
  Jido actions.
- Runtime-facing action invocation should resolve through
  `AllbertAssist.Actions.Registry` and execute through
  `AllbertAssist.Actions.Runner.run/3`.
- Workspace canvas, ephemeral surface, Fragment, and offline-edit behavior
  belongs behind `AllbertAssist.Workspace`, signals, and registered actions;
  LiveViews render and dispatch but do not own workspace authority.
- Security decisions and permission checks belong at the action boundary.
  Skills, model output, app metadata, plugin metadata, YAML declarations, and
  generated files never grant permission by themselves.
- Do not auto-generate, compile, or load Elixir modules from arbitrary skill,
  plugin, YAML, or user-created folders.
  v0.36 (ADR 0037) plans only the Elixir/OTP sandbox and gate runner: generated
  code may be compiled/tested in a configured OS sandbox with approved local
  images and source-policy checks, but that produces a report only and grants no
  live authority. v0.37 (ADR 0032, ADR 0033, ADR 0035) defines the only planned
  hot-load exception: a file-backed draft under Allbert Home may be loaded into
  the core node only after the v0.36 gate passes and the operator explicitly
  confirms an audited, reversible integration. Untrusted/arbitrary loading,
  integration without the gate, and integration authorized by advisory/agent
  output remain fully forbidden. Until v0.37 ships, no dynamic loading is
  permitted.
- Do not execute skill scripts, shell commands, external installs, network
  adapters, bridge processes, or provider calls unless a plan explicitly adds
  the permission, confirmation, sandbox, and trace story.
- Do not call `npx skills add`, `git clone`, package managers, or external
  installer CLIs from skill activation, online skill search, imported skill
  metadata, plugin discovery, or model output.
- Do not treat OTP supervision, BEAM processes, or local child processes as an
  OS security boundary. Host execution must be policy-bounded through
  registered actions; deeper isolation requires a later plan and ADR update.
- Multi-step / cross-turn work uses the v0.24 objective runtime
  (`AllbertAssist.Objectives`). Apps, plugins, channels, and LiveViews
  must not implement private durable goal loops; the shared
  objectives/objective_steps/objective_events tables and
  `Objectives.Engine` are the only sanctioned substrate. Use the public
  `AllbertAssist.Objectives` lifecycle facade or registered objective actions
  for transitions; lower-level store helpers are internal runtime helpers.
- `objective_id` and `step_id` are never authority. Advisory provider
  output (LLM proposers, world-model predictors, diffusion proposers,
  market allocators, probabilistic critics, agent-behavior simulators)
  is never authority. Predictions about user behavior never
  short-circuit confirmation, regardless of confidence or calibration.
- Choose Jido.Agent or plain GenServer per the pragmatic rule in the
  "Jido.Agent vs. GenServer" section of `docs/plans/allbert-jido-vision.md`.
  New state-bearing modules document the substrate choice in their
  module `@moduledoc`. As of v0.23, `IntentAgent`,
  `Confirmations.Store.Agent`, and `Jobs.Scheduler.Agent` are Jido agents;
  v0.24 adds `Objectives.Engine.Agent`. Storage components (`Settings`,
  `Trace`, `Memory` IO, `Session.Scratchpad`, `Memory.Compiler`,
  `Memory.Promotion`) are plain GenServers/modules.
- Private Jido command modules inside those agents are not Allbert capability
  actions. Do not register them in `AllbertAssist.Actions.Registry` or expose
  them as intent candidates.
- Use `Req` for HTTP. Do not add `:httpoison`, `:tesla`, or `:httpc`.

## Workflow

- For docs-only changes, run `git diff --check`.
- For code changes, run focused tests first, then finish with the milestone
  warning gate: `mix compile --warnings-as-errors`, `mix credo --strict`,
  `mix dialyzer`, and `mix precommit`, unless the user explicitly scopes the
  work differently.
- Update request-flow docs as implementation changes.
- Add or update ADRs when an implementation decision constrains future design.
- Keep LiveViews thin: they call contexts/actions/runtime boundaries and do not
  own agent logic, settings semantics, or security policy.
