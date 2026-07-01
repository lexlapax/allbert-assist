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

The current release is `v0.60.1` (v0.60b, Visual Design Language & Art Direction),
a design-first **point release** on top of `v0.60.0` (Product Experience Design).
v0.60 front-loaded the unified journey, information architecture, First-Model Path,
onboarding/persona inputs, entry-point UX, design-system gap analysis, and a navigable
placeholder walking skeleton. v0.60b then designed the product's **visual language**:
it produced three divergent candidate visual directions as rendered hero screens,
evaluated them against a rubric, and the operator **chose Direction C (Soft Modern
Depth)** as the canonical language that v0.61 will implement. Both are design-first and
ship no new authority or runtime capability beyond the inert preview scaffold.

The latest published release tag is `v0.60.0`; the `v0.60.1` tag is pending operator
approval (version metadata already reports `0.60.1`).

This README is the stable project orientation; release-by-release implementation
detail belongs in [CHANGELOG.md](CHANGELOG.md), and forward planning belongs in
[docs/plans/roadmap.md](docs/plans/roadmap.md).

Today, Allbert includes:

- A local assistant runtime that routes user input through registered actions.
- A web workspace at `/workspace`.
- Terminal and CLI operator surfaces.
- Durable confirmations for sensitive work.
- Settings Central for operator-tunable configuration.
- Security Central for permission and policy decisions.
- Markdown-first memory under Allbert Home.
- Inspectable traces, events, objectives, jobs, and operator reports.
- Source-tree plugins and app surfaces, with StockSage as the main reference app.
- Public protocol surfaces with bounded, policy-checked exposure.

This is still a developer-operated local project, not a polished consumer app
installer. It expects a local checkout, configured providers or local model
endpoints where needed, and an operator who is comfortable running validation
commands during release work.

## What Allbert Is For

Allbert is for building a personal AI environment where the assistant can:

- answer and route local requests;
- remember information only through reviewable memory paths;
- resume longer-running work through objectives;
- expose app-specific workflows through reviewed plugins;
- show what settings, models, intents, jobs, and policies are active;
- connect to external tools only through explicit, policy-bounded actions.

It is especially focused on the boundary between useful autonomy and operator
control. Model output, plugin metadata, YAML, generated files, and app surfaces do
not grant authority by themselves. Authority comes from registered actions,
settings, policy checks, and confirmations.

## Built On

Allbert is implemented with Elixir, OTP, Phoenix LiveView, SQLite, and Jido.
Those details matter for contributors, but the user-facing promise is simpler:
a supervised local assistant runtime with inspectable state, explicit authority
boundaries, and multiple operator surfaces over the same core.

## Where It Is Going

Allbert is moving toward a local assistant operating system: a place where
conversations, memory, settings, tools, background work, plugins, and app
surfaces share one authority model.

The roadmap is intentionally incremental. Each release proves a small contract in
the real runtime, documents the boundary, validates it, and only then makes that
contract easier to reuse.

See [docs/plans/roadmap.md](docs/plans/roadmap.md) for the current milestone
sequence and [CHANGELOG.md](CHANGELOG.md) for shipped release details.

## Start Here

If you want to try Allbert locally:

- [docs/operator/onboarding.md](docs/operator/onboarding.md): first local run and
  operator orientation.
- [docs/operator/workspace.md](docs/operator/workspace.md): the web workspace,
  panels, and operator-facing controls.
- [docs/README.md](docs/README.md): the documentation map.
- [CHANGELOG.md](CHANGELOG.md): what has shipped and what the current release
  includes.
- [docs/plans/roadmap.md](docs/plans/roadmap.md): where the project is going next.

If you are contributing to the codebase:

- [DEVELOPMENT.md](DEVELOPMENT.md): local setup, commands, and verification gates.
- [AGENTS.md](AGENTS.md): repository rules for coding agents and agent-assisted
  work.
- [docs/developer/agent-context-map.md](docs/developer/agent-context-map.md):
  subsystem routing map for deeper work.
- [docs/developer/test-strategy.md](docs/developer/test-strategy.md): test lane
  taxonomy and release gate structure.
- [docs/adr/README.md](docs/adr/README.md): architectural decisions.

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
