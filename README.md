# Allbert Assist

Allbert Assist is a local-first personal AI assistant workspace.

It is designed for people who want an assistant they can run, inspect, configure,
and grow over time. Allbert can hold conversations, remember operator-reviewed
information, route requests to approved capabilities, ask for confirmation before
sensitive work, and keep records of what happened.

Allbert is not just a chatbot with tools attached. Its core idea is that every
surface — the web workspace, terminal/TUI, CLI tasks, channels, plugins, and
public protocol endpoints — should go through the same runtime, settings,
security, confirmation, and trace system. Asking from the browser or asking from
the terminal should not create a different authority model.

## Why It Exists

Most agent systems become hard to understand as they gain tools, plugins, memory,
background jobs, and external connections. Allbert exists to make that growth
inspectable.

The project is built around a few practical rules:

- Keep local data local by default.
- Make memory readable and reviewable.
- Put side effects behind named actions.
- Ask for confirmation when work is sensitive.
- Record traces and events so the operator can see what happened.
- Treat plugins, generated capabilities, and app surfaces as reviewed extensions,
  not automatic permission grants.

The long-term goal is a personal assistant that can grow with its user without
becoming opaque or unbounded.

## Current Shape

The current released version is `v0.58.0` (M15 closeout 2026-06-25; the release
tag is applied separately per project convention). This README is
the stable project orientation;
release-by-release implementation detail belongs in
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
then make the contract easier to reuse. Operator-facing provider milestones
target real configured endpoints; fake providers are test fixtures only.

See [docs/plans/roadmap.md](docs/plans/roadmap.md) for the current milestone
sequence and [CHANGELOG.md](CHANGELOG.md) for shipped release details.

## Start Here

- [AGENTS.md](AGENTS.md): repository rules for coding agents.
- [DEVELOPMENT.md](DEVELOPMENT.md): local setup, commands, and verification
  gates.
- [docs/developer/agent-context-map.md](docs/developer/agent-context-map.md):
  subsystem routing map for deeper work.
- [docs/developer/surface-contract.md](docs/developer/surface-contract.md):
  v0.58 cross-surface implementation contract and conformance checklist.
- [docs/developer/web-design-system.md](docs/developer/web-design-system.md):
  v0.58 web tokens, variants, pattern library, and shell contract.
- [docs/operator/workspace.md](docs/operator/workspace.md): operator workspace
  guide for the chat-primary shell, panels, and surface policy.
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
