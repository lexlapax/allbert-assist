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

This README is the stable project orientation. The current packaged release is
**v1.0.5**. For its features and the full release-by-release history, see the
[CHANGELOG](CHANGELOG.md); forward planning lives in the
[roadmap](docs/plans/roadmap.md).

Today, Allbert includes:

- A local assistant runtime that routes user input through registered actions.
- A web workspace at `/workspace`, plus terminal/CLI operator surfaces.
- Durable confirmations for sensitive work.
- Settings Central for operator-tunable configuration.
- Security Central for permission and policy decisions.
- Markdown-first memory under Allbert Home, plus local files/notes as a launch
  integration.
- Inspectable traces, events, objectives, jobs, and operator reports.
- Source-tree plugins and app surfaces, with StockSage as the main reference app.
- Public protocol surfaces with bounded, policy-checked exposure.

The packaged install and repairable first run make Allbert usable by a
non-developer across the curl and Homebrew paths. The pre-1.0 plan closes the
remaining launch gap explicitly: v0.66 owns no-docs product RC validation before
v1.0 freezes the public contracts.

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
- [docs/operator/local-knowledge.md](docs/operator/local-knowledge.md): connect
  local files/notes and reviewed agent memory (the launch integration).
- [docs/operator/install.md](docs/operator/install.md): packaged install,
  upgrade, uninstall, and distribution-trust notes.
- [docs/README.md](docs/README.md): the documentation map.
- [CHANGELOG.md](CHANGELOG.md) / [docs/plans/roadmap.md](docs/plans/roadmap.md):
  what has shipped and where the project is going next.

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

For contributors working from source (the packaged product install path is in
[docs/operator/install.md](docs/operator/install.md)). The common loop:

```sh
mix setup
mix test
mix allbert.test fast-local
mix precommit
mix phx.server
```

Use a temporary `ALLBERT_HOME` for tests, release smoke checks, and manual
verification so real local assistant data is never modified by accident. See
[DEVELOPMENT.md](DEVELOPMENT.md) for the full command set and operator examples.
