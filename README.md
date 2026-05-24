# Allbert Assist

Allbert Assist is a local-first assistant runtime for long-running personal
work. It is built as an Elixir/Phoenix umbrella application around supervised
OTP processes, Jido actions and agents, durable confirmations, Security
Central, Settings Central, markdown-first memory, Allbert Home, and inspectable
runtime traces.

Phoenix LiveView, Mix tasks, channels, and plugin apps are operator surfaces
over the runtime. The center of the system is the signal-driven assistant
runtime and its registered action boundary.

## Why It Exists

Allbert exists to make a personal assistant that is useful without becoming
opaque. It keeps local data local, requires explicit confirmation for sensitive
work, records what happened, and treats apps and plugins as reviewed
extensions rather than unchecked authority.

The project direction is intentionally practical: ship small, auditable
contracts; prove each one through a real app; then make those contracts easier
to generate and reuse.

## Current State

The current implementation is `v0.35.0`, ready for operator manual
verification. `/workspace` is the only operator home: chat is the primary
spine, the left rail is a view-only launcher, and Canvas shows one destination
at a time (Output, an app, or a workspace tool). Operators can retheme and
re-lay-out the workspace from local Allbert Home files through Settings
Central-accountable gates, while neutral workspace chat can recognize reviewed
app-owned capabilities without silently running them. App routing context is
still set only by accepting an explicit conversational handoff.

Recent platform contracts now in place:

- `v0.26.2`: workspace UX closeout for the `/agent` canvas shell.
- `v0.27.0`: app surface contract, proven through StockSage-owned LiveViews.
- `v0.28.0`: security hardening and adversarial evals across app surfaces,
  workspace fragments, objectives, resource access, and StockSage boundaries.
- `v0.29.0`: app memory and outcomes contract, proven through StockSage.
- `v0.30.0`: app canvas contract, proven through durable StockSage canvas
  tiles in `/agent`.
- `v0.31.0`: runtime and UI-substrate consolidation before the workspace UI,
  theming, dynamic draft, and generator arc.
- `v0.32.0`: workspace-only app UI and Settings Central, with app UI composed
  through host-owned panel zones in `/workspace`.
- `v0.33.1`: conversational app intent handoff and direct-answer foundation,
  with app-contributed intent descriptors, explicit neutral handoff, targeted
  clarification, advisory-only classifier selection, and descriptor-backed
  StockSage analysis/trend/queue prompts.
- `v0.34.0`: workspace UX refresh with chat-primary shell, view-only launcher,
  single-destination Canvas, Settings/tools in Canvas, passive context
  indicator, desktop Canvas focus, and mobile launcher sheet + Chat/Canvas
  tabs.
- `v0.35.0`: user theming and layout overrides from Allbert Home, with
  presentational token YAML, opt-in sanitized CSS snippets, validated launcher
  and Canvas destination layout data, Settings Canvas accountability, and CSP
  regression coverage.

Released history belongs in [CHANGELOG.md](CHANGELOG.md). Forward planning
lives in [docs/plans/roadmap.md](docs/plans/roadmap.md).

## What It Can Do Today

Allbert can accept operator input through CLI and the `/workspace` Phoenix
LiveView, route effectful work through registered Jido actions, require durable
confirmations, store local conversation history, run scheduled jobs, frame
cross-turn objectives, inspect traces, review markdown memory, and host
reviewed plugin apps through workspace panels.

StockSage is the reference plugin app. It exercises the app, objective,
security, native-agent, LiveView surface, memory-sync, and canvas contracts
through a concrete financial-analysis workflow.

## Built On

- Elixir, OTP, Phoenix, Phoenix LiveView, Ecto, and SQLite.
- Jido actions and Jido-backed agents for runtime work and state machines.
- A signal bus and trace system for observable assistant behavior.
- Settings Central for operator configuration.
- Security Central, Resource Access, and confirmation records for permissioned
  work.
- Markdown-first memory and Allbert Home (`ALLBERT_HOME`) for local durable
  state.
- Source-tree plugins for reviewed apps, channels, actions, settings, and
  skills.

## Vision

Allbert is moving toward a local assistant operating system: apps expose
reviewed surfaces, actions remain policy-bound, objectives carry long-running
work, memory stays inspectable, and generated apps inherit contracts that were
manually proven first.

Near-term milestones:

- `v0.31`: runtime and UI-substrate consolidation — action DSL, unified
  surface/catalog/registry paths, settings fragments, typed responses, and
  shared path/redaction/audit/persistence facades.
- `v0.32`: workspace-only app UI — `/workspace` is the operator home,
  Settings Central is in the workspace, and apps contribute panels instead of
  separate app shells.
- `v0.33`: conversational app intent handoff and direct-answer foundation —
  neutral workspace prompts can propose app handoff or clarification without
  silently executing app-owned actions.
- `v0.34`: workspace UX refresh — implemented with a chat-centered shell, a
  view-only left launcher, a single-destination Canvas, and routing context set
  conversationally through the v0.33 handoff (no permanent Tools column or
  floating panel band).
- `v0.35`: user theming and layout overrides from `~/.allbert` — implemented as
  the current milestone with token themes, opt-in sanitized CSS snippets,
  validated workspace layout data, Settings accountability, and CSP checks.
- `v0.36`: Elixir/OTP sandbox and gate runner — a default-off, OS-aware sandbox
  (pluggable backend registry + `:auto` resolver: Apple `container` on supported
  macOS, Podman/Docker on Linux, Docker fallback, optional `runsc`) for
  generated Elixir/OTP drafts and explicit gate commands, producing bounded
  reports without live loading.
- `v0.37`: dynamic code & config generation and live capability integration —
  LLM code-gen agents generate to the proven shapes, trial through the v0.36
  sandbox, and (after the warning gate plus operator confirmation) hot-load into
  the live runtime without a restart (audited and reversible).
- `v0.38`: templated creation — vetted plugin/app/LLM-tool/scheduled-flow/code
  templates via Mix tasks, operator workspace flows, and a Canvas Create
  surface, reusing the v0.36 sandbox and v0.37 loader.
- Post-`v0.38`: broader UI protocol interop, richer generated app workflows,
  and additional reviewed app/plugin surfaces.

## Start Here

- [AGENTS.md](AGENTS.md): repository rules for coding agents.
- [DEVELOPMENT.md](DEVELOPMENT.md): local setup, commands, and verification
  gates.
- [docs/developer/agent-context-map.md](docs/developer/agent-context-map.md):
  subsystem routing map for deeper work.
- [docs/plans/roadmap.md](docs/plans/roadmap.md): active roadmap and upcoming
  milestones.
- [CHANGELOG.md](CHANGELOG.md): released-history details.
- [docs/adr](docs/adr): architectural decisions.
- [docs/plans/v0.35-plan.md](docs/plans/v0.35-plan.md): current implemented
  milestone plan.
- [docs/plans/v0.35-request-flow.md](docs/plans/v0.35-request-flow.md):
  request flows and manual verification notes for `v0.35.0`.

## Local Development

Common development loop:

```sh
mix setup
mix test
mix precommit
mix phx.server
```

Operator examples:

```sh
mix allbert.ask --user local --active-app stocksage "analyze AAPL"
mix allbert.confirmations list --user local
mix allbert.objectives list --user local
mix allbert.memory review --user local
mix allbert.security status
```

Use a temporary `ALLBERT_HOME` for tests, release smoke checks, and manual
verification so real local assistant data is never modified by accident.
