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

The current implementation is `v0.37.5`. `/workspace` is the operator home:
chat is the primary spine, the launcher is view-only, and Canvas shows one
destination at a time (Output, an app, or a workspace tool).

Allbert now has the runtime contracts needed for local assistant work:
registered Jido actions and agents, durable confirmations, Settings Central,
Security Central, local traces, markdown memory, jobs, objectives, reviewed
plugin apps, StockSage as the reference app, Allbert Home-based theming/layout
overrides, a default-off report-only Elixir/OTP sandbox and gate runner, and a
default-off dynamic draft/live integration path for reviewed read-only and
delegated memory/network action artifacts.

Released history belongs in [CHANGELOG.md](CHANGELOG.md). Forward planning
lives in [docs/plans/roadmap.md](docs/plans/roadmap.md).

## What It Can Do Today

Allbert can accept operator input through CLI and the `/workspace` Phoenix
LiveView, route effectful work through registered Jido actions, require durable
confirmations, store local conversation history, run scheduled jobs, frame
cross-turn objectives, inspect traces, review markdown memory, and host
reviewed plugin apps through workspace panels. It can also build disposable
Elixir/OTP sandbox bundles, produce report-only sandbox/gate evidence, record
dynamic draft requests, and live-register gate-passed dynamic actions after
explicit operator confirmation in a disposable Allbert Home. Generated actions
can be pure read-only or delegate memory/network effects through reviewed
facades with their normal confirmations.

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

- `v0.38`: templated creation — vetted plugin/app/LLM-tool/scheduled-flow/code
  templates via Mix tasks (`--target` defaults to `./plugins/<name>`), operator
  workspace flows, and a Canvas Create surface, reusing the v0.36 sandbox and
  v0.37 loader.
- Post-`v0.38`: the planned 1.0 arc shifts from substrate work to operator
  reach: first-run onboarding and provider control (`v0.39`), MCP client
  integration (`v0.40`), everyday integrations (`v0.41`), browser research
  (`v0.42`), Discord/Slack channels (`v0.43`), Plan/Build workflows (`v0.44`),
  marketplace lite (`v0.45`), operator-supervised self-improvement (`v0.46`),
  voice and vision (`v0.47`/`v0.48`), mobile messaging plus protocol interop
  (`v0.49`), final hardening/export-import/RC evidence (`v0.50`), and a
  no-new-features public contract freeze at `v1.0`.

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
- [docs/plans/v0.36-plan.md](docs/plans/v0.36-plan.md): implemented sandbox
  and gate-runner contract.
- [docs/plans/v0.37-plan.md](docs/plans/v0.37-plan.md): released dynamic
  draft, delegated facade, and gated live-integration milestone.
- [docs/plans/v0.38-plan.md](docs/plans/v0.38-plan.md): templated creation
  milestone after v0.37.

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
