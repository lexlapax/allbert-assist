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

The current implementation is `v0.46.0`. `/workspace` is the operator home:
chat is the primary spine, the launcher is view-only, and Canvas shows one
destination at a time (Output, an app, or a workspace tool).

Allbert now has the core contracts needed for local assistant work:
registered actions, Jido-backed agents, durable confirmations, Security
Central, Settings Central, Resource Access, local traces, markdown memory,
objectives, reviewed plugin apps, browser-backed research, operator workflow
YAML, marketplace-lite reviewed assets, and release gates that produce
bounded evidence.

The major surfaces are:

- Runtime: registered actions, objectives, delegate agents, confirmations,
  traces, memory, and scheduled jobs.
- Operator UI: Phoenix LiveView `/workspace`, CLI tasks, workspace panels, and
  Canvas destinations.
- Plugin ecosystem: source-tree apps and plugins, StockSage as the reference
  app, browser/research, notes/files, channel plugins, marketplace-lite seeds,
  and documented delegate-agent extension points.
- Safety and operations: Security Central, Resource Access, Settings Central,
  Allbert Home, redaction, eval inventories, version-specific release gates,
  and opt-in external smokes.

Release-by-release implementation detail belongs in [CHANGELOG.md](CHANGELOG.md).
Forward planning lives in [docs/plans/roadmap.md](docs/plans/roadmap.md).

## What It Can Do Today

Allbert can accept operator input through CLI and the `/workspace` Phoenix
LiveView, route effectful work through registered Jido actions, require durable
confirmations, store local conversation history, run scheduled jobs, frame
cross-turn objectives, inspect traces, review markdown memory, and host
reviewed plugin apps through workspace panels.

It can also scaffold reviewed plugin/app/tool/flow patterns, build disposable
Elixir/OTP sandbox bundles, produce report-only sandbox/gate evidence, record
dynamic draft requests, and live-register gate-passed dynamic actions after
explicit operator confirmation in a disposable Allbert Home. Generated actions
can be pure read-only or delegate memory/network effects through reviewed
facades with their normal confirmations.

It can discover MCP server candidates without connecting them, connect a
discovered server only after operator consent that shows the exact command/URL,
open Calendar/Mail/GitHub workspace panels backed by configured MCP servers,
read/search/write local notes through the notes/files reference plugin, run
policy-bounded browser extraction, execute operator workflow YAML through the
Objective Runtime, and delegate read-only research work to
`research.specialist`.

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

The current release (`v0.46.0`) finishes the delegate-agent hardening step by
proving the objective delegation contract against StockSage and read-only
browser research. The next planned release is operator-supervised
self-improvement (`v0.47`), followed by multimodal inputs, channel plugins,
MCP server mode, final hardening, and a no-new-features tiered public contract
freeze at `v1.0`.

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
- [docs/plans/v0.46-plan.md](docs/plans/v0.46-plan.md): implemented
  delegation hardening and research specialist milestone.
- [docs/operator/research-specialist.md](docs/operator/research-specialist.md):
  operator guide for the shipped `research.specialist` delegate.
- [docs/developer/test-strategy.md](docs/developer/test-strategy.md): test
  lane taxonomy, gate matrix, isolation contract, and implementation-plan
  parallelization annotations.

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
