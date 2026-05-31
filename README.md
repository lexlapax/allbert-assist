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

The current implementation is `v0.42.2`. `/workspace` is the operator home:
chat is the primary spine, the launcher is view-only, and Canvas shows one
destination at a time (Output, an app, or a workspace tool).

Allbert now has the runtime contracts needed for local assistant work:
registered Jido actions and agents, durable confirmations, Settings Central,
Security Central, local traces, markdown memory, jobs, objectives, reviewed
plugin apps, StockSage as the reference app, Allbert Home-based theming/layout
overrides, a default-off report-only Elixir/OTP sandbox and gate runner, and a
default-off dynamic draft/live integration path for reviewed read-only and
delegated memory/network action artifacts. v0.38 adds deterministic templated
creation for reviewed plugin, app, LLM-tool, scheduled-flow, and objective
workflow patterns through developer Mix tasks and the default-off
`workspace:create` Canvas destination. v0.39 adds first-run onboarding through
`mix allbert.onboard` and `workspace:onboard`, provider/model control through
`mix allbert.model`, the explicit `providers.*.endpoint_kind` setting, and a
two-branch provider doctor for credentialed remotes and local endpoints with
the redacted ADR 0047 return shape. v0.39b adds the inert `identity` system
memory namespace, the 5th `Memory` category, deterministic direct-answer
Active Memory retrieval over reviewed `:kept` entries, Active Memory trace
metadata, and `mix allbert.memory retrieve --query`. With an explicit
`ALLBERT_HOME` or `ALLBERT_HOME_DIR`, `mix phx.server` also bootstraps a
missing or empty dev SQLite database before Phoenix starts. v0.40 adds MCP
client integration: Settings Central `mcp.servers.*`, `secret://mcp/...` refs,
Hermes-backed MCP message codec with Allbert-owned HTTP/SSE and stdio
transports, `mcp://` Resource Access, grant-gated MCP resource reads, and
per-call-confirmed MCP tool calls.
v0.42 adds tool discovery and the first MCP-first integration pack:
`find_tools`, `find_mcp_tools`, `mcp_fetch_server_manifest`,
`mcp_evaluate_server`, the confirmation-gated `mcp_server_connect` gate,
passive Discovery Suggestions, MCP-configured Calendar/Mail/GitHub panels,
integration intent handoffs, and `./plugins/allbert.notes_files/` as the native
reference plugin. The 0.42.1/0.42.2 closeout hardens the discovery permission
boundary, live trust baseline, CLI connect contract, notes/files metadata, real
integration effect arguments, and deterministic `release.v042` gate.

Released history belongs in [CHANGELOG.md](CHANGELOG.md). Forward planning
lives in [docs/plans/roadmap.md](docs/plans/roadmap.md).

## What It Can Do Today

Allbert can accept operator input through CLI and the `/workspace` Phoenix
LiveView, route effectful work through registered Jido actions, require durable
confirmations, store local conversation history, run scheduled jobs, frame
cross-turn objectives, inspect traces, review markdown memory, and host
reviewed plugin apps through workspace panels. It can also scaffold reviewed
plugin/app/tool/flow patterns, build disposable Elixir/OTP sandbox bundles,
produce report-only sandbox/gate evidence, record dynamic draft requests, and
live-register gate-passed dynamic actions after explicit operator confirmation
in a disposable Allbert Home. Generated actions can be pure read-only or
delegate memory/network effects through reviewed facades with their normal
confirmations.
It can discover MCP server candidates without connecting them, connect a
discovered server only after operator consent that shows the exact command/URL,
open Calendar/Mail/GitHub workspace panels backed by configured MCP servers,
and read/search/write local notes through the notes/files reference plugin.

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

Recent milestones:

- `v0.42.2`: Tool Discovery + MCP-First Integration Pack 1 - unified
  `find_tools`, internet MCP registry discovery, connect consent, rug-pull
  baseline checks, passive Discovery Suggestions, Calendar/Mail/GitHub
  MCP-configured workspace panels, integration intent handoffs, and the
  notes/files native reference plugin, with closeout hardening and a
  deterministic release smoke gate.
- `v0.41.0`: Developer velocity and parallel test methodology - gate matrix,
  resource-lane taxonomy, partition-aware test helpers, focused/release aliases,
  and implementation-readiness annotations for downstream plans.
- `v0.40.0`: MCP client integration - configured MCP servers, secret refs,
  doctor/list/read/call actions, grant-gated `mcp://` resource reads,
  per-call-confirmed tool calls, executable MCP security evals, and approved
  real-server smoke against the official GitHub MCP server.

Next milestones:

- Post-`v0.42.2`: the planned 1.0 arc continues with browser research
  (`v0.43`); Discord/Slack channels with the
  channel-approval-primitive contract (`v0.44`); Plan/Build workflows under
  `<ALLBERT_HOME>/workflows/` (`v0.45`); marketplace lite — data shape +
  Allbert-author seeds only (`v0.46`); operator-supervised self-improvement
  (`v0.47`); voice (`v0.48`); vision (`v0.49`); mobile messaging
  WhatsApp/Signal/Matrix (`v0.50`); MCP server mode (`v0.50b`); final
  hardening/export-import/settings-schema-migration/RC evidence (`v0.51`);
  and a no-new-features **tiered** public contract freeze at `v1.0`.

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
- [docs/plans/v0.38-plan.md](docs/plans/v0.38-plan.md): implemented templated
  creation milestone after v0.37.
- [docs/plans/v0.39-plan.md](docs/plans/v0.39-plan.md): implemented
  first-run onboarding and provider-control milestone.
- [docs/plans/v0.39b-plan.md](docs/plans/v0.39b-plan.md): implemented
  identity slot and Active Memory milestone.
- [docs/plans/v0.40-plan.md](docs/plans/v0.40-plan.md): implemented MCP
  client integration milestone.
- [docs/plans/v0.41-plan.md](docs/plans/v0.41-plan.md): implemented developer
  velocity and parallel test methodology milestone, including the temporary
  Memento/Jido compatibility override recorded in ADR 0050.
- [docs/plans/v0.42-plan.md](docs/plans/v0.42-plan.md): implemented tool
  discovery and MCP-first integration pack milestone.
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
