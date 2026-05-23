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

The current release is `v0.30.0`. It completes the app canvas contract:
StockSage analysis lifecycle signals now emit durable `/agent` workspace
canvas tiles through the audited Fragment/canvas path, and those tiles render
with the same StockSage card components proven in `/stocksage/*`.

Recent platform contracts now in place:

- `v0.26.2`: workspace UX closeout for the `/agent` canvas shell.
- `v0.27.0`: app surface contract, proven through StockSage-owned LiveViews.
- `v0.28.0`: security hardening and adversarial evals across app surfaces,
  workspace fragments, objectives, resource access, and StockSage boundaries.
- `v0.29.0`: app memory and outcomes contract, proven through StockSage.
- `v0.30.0`: app canvas contract, proven through durable StockSage canvas
  tiles in `/agent`.

Released history belongs in [CHANGELOG.md](CHANGELOG.md). Forward planning
lives in [docs/plans/roadmap.md](docs/plans/roadmap.md).

## What It Can Do Today

Allbert can accept operator input through CLI and Phoenix LiveView, route
effectful work through registered Jido actions, require durable confirmations,
store local conversation history, run scheduled jobs, frame cross-turn
objectives, inspect traces, review markdown memory, and host reviewed plugin
apps.

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

- `v0.31`: plugin/app generator, scaffolding the surface, memory, action,
  objective, and canvas contracts after they have been proven manually.
- Post-`v0.31`: broader UI protocol interop, richer generated app workflows,
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
- [docs/plans/v0.30-plan.md](docs/plans/v0.30-plan.md): current implemented
  milestone plan.
- [docs/plans/v0.30-request-flow.md](docs/plans/v0.30-request-flow.md):
  request flows and manual verification notes for `v0.30.0`.

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
