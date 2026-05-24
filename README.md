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

The current implementation is the released `v0.33.1`. `/workspace` is the
only operator home, and neutral workspace chat can now recognize reviewed
app-owned capabilities without silently running them. Plain questions use the
side-effect-free direct-answer path; neutral app-like prompts such as
`analyze CIEN` render an explicit StockSage handoff or targeted clarification;
accepting the handoff sets active app context before the normal confirmation
flow begins. StockSage `run_analysis`, `get_trends`, and `queue_analysis`
conversational routing now all use app-contributed intent descriptors rather
than core StockSage symbol-parsing shortcuts.

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
  implemented as the current release; neutral workspace prompts can propose
  app handoff or clarification without silently executing app-owned actions.
- `v0.34`: workspace UX refresh — chat-centered shell, a view-only left
  launcher, a single-destination Canvas, and routing context set
  conversationally through the v0.33 handoff (no permanent Tools column or
  floating panel band).
- `v0.35`: user theming and layout overrides from `~/.allbert`, with token
  themes, opt-in sanitized CSS snippets, and validated workspace layout data.
- `v0.36`: dynamic plugin/app generation and sandboxed module loading for
  inert local drafts under Allbert Home, compiled and tried only out of node.
- `v0.37`: plugin/app generator, scaffolding the surface, panel, settings,
  intent descriptor, memory, action, objective, canvas, theming, and
  dynamic-draft review contracts after they have been proven manually.
- Post-`v0.37`: broader UI protocol interop, richer generated app workflows,
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
- [docs/plans/v0.33-plan.md](docs/plans/v0.33-plan.md): current implemented
  milestone plan.
- [docs/plans/v0.33-request-flow.md](docs/plans/v0.33-request-flow.md):
  request flows and manual verification notes for `v0.33.1`.

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
