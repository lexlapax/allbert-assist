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

## Current Shape

The current implementation is `v0.49.0`. This README is the stable project
orientation; release-by-release implementation detail belongs in
[CHANGELOG.md](CHANGELOG.md), and forward planning belongs in
[docs/plans/roadmap.md](docs/plans/roadmap.md).

At the project level, Allbert has four durable parts:

- A signal-driven runtime that resolves registered actions, frames objectives,
  records traces, and keeps permission checks at the action boundary.
- Operator surfaces, including Phoenix LiveView `/workspace`, Mix tasks,
  channels, and plugin panels, that render and dispatch but do not own runtime
  authority.
- A reviewed extension model for source-tree plugins, apps, actions, settings,
  channels, workflows, and delegate agents.
- A local operating posture built around Allbert Home, Settings Central,
  Security Central, confirmations, redaction, and release gates with bounded
  evidence.

StockSage remains the reference plugin app for exercising the platform through
a concrete domain workflow. Other shipped plugins and operator guides document
the same contracts in narrower surfaces.

## Capability Summary

Allbert supports local operator conversations, reviewed plugin app surfaces,
durable confirmations, trace inspection, markdown memory review, scheduled
jobs, and cross-turn objectives. Effectful work flows through registered Jido
actions and policy checks instead of being granted by model output, app
metadata, workflow YAML, or generated files.

The platform also supports reviewed workflow and extension paths: operator
workflow YAML runs through the Objective Runtime, MCP integrations connect only
after operator consent, browser-backed work stays policy-bounded, and dynamic
code paths remain gated, report-producing, and explicitly confirmed before any
live registration.

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

The roadmap is intentionally incremental: prove a contract through real
runtime use, document its authority boundary, add release evidence, and only
then make the contract easier to reuse. The current roadmap sequence has
operator-supervised self-improvement discovery/local drafts in v0.47, handoff
drafts in v0.47b/`0.47.1`, provider-capability-backed voice in v0.48, and
vision/image generation in v0.49.
Fake providers are test fixtures only; operator-facing provider milestones
target real configured endpoints/providers.
Vision/image generation in v0.49 consumes the v0.48 provider capability
substrate rather than adding a separate image-provider framework.
Use [CHANGELOG.md](CHANGELOG.md) for shipped release details and
[docs/plans/roadmap.md](docs/plans/roadmap.md) for the current milestone
sequence.

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
- [docs/developer/test-strategy.md](docs/developer/test-strategy.md): test
  lane taxonomy, gate matrix, isolation contract, and implementation-plan
  parallelization annotations.
- [docs/samples/media](docs/samples/media): committed sample audio and image
  files for operator manual validation, documentation examples, and focused
  media smoke testing.

## Local Development

Common development loop:

```sh
mix setup
mix test
mix allbert.test fast-local
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
