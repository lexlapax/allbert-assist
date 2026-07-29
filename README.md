# Allbert Assist

Allbert Assist is my personal AI assistant, developed in the open.

It is built for a single user — me — running on my own machine, with data kept
local. Everything in it is shaped by what I actually need an assistant to do:
hold conversations, remember information I have reviewed, route requests to
approved capabilities, ask before doing sensitive work, and keep an honest record
of what happened.

Allbert is not a chatbot with tools attached. Its core idea is that every
surface — the web workspace, terminal/TUI, CLI tasks, channels, plugins, and
public protocol endpoints — goes through the same runtime, settings, security,
confirmation, and trace system. Asking from the browser and asking from the
terminal should not create a different authority model.

Throughout the code and docs, the single person who runs and configures an
Allbert instance is called the **operator**. If you run Allbert, that is you.

## Running It Yourself

You are welcome to. Install, first run, and onboarding are deliberately smooth,
and that took real effort — a working install should get you to a chat without a
developer standing next to you. If what you want is a local-first assistant you
own and can inspect, Allbert may fit.

What that welcome does not include:

- **It is not a product.** There is no hosted service, no accounts, and no
  multi-user or multi-tenant mode. One instance, one operator, one machine.
- **There is no support.** I read issues when I have time. Please do not depend
  on a reply, a fix, or a timeline.
- **The roadmap follows my use, not a backlog.** Features land because I wanted
  them. Requests are interesting to read but do not create obligations.
- **No stability promises.** Releases are versioned and the CHANGELOG is honest,
  but I will change things that get in my way.

None of that is discouragement. It is just the accurate shape of the project, so
you can decide with open eyes. The code is Apache-2.0 — see
[License](#license) — so the permission to run, fork, and modify it is real
regardless of what I can promise about support.

## Why It Exists

Most agent systems become hard to understand as they gain tools, plugins, memory,
background jobs, and external connections. I built Allbert to make that growth
inspectable — because I intend to keep growing it, and I want to keep being able
to see what it is doing.

The rules I hold it to:

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
**v1.2.0**. For its features and the full release-by-release history, see the
[CHANGELOG](CHANGELOG.md); forward planning lives in the
[roadmap](docs/plans/roadmap.md).

Today, Allbert includes:

- A local assistant runtime that routes user input through registered actions.
- A web workspace at `/workspace`, plus terminal/CLI operator surfaces.
- Durable confirmations for sensitive work.
- Durable supervised fan-out with in-channel steering and one honest joined
  report across terminal, Web, and supported chat surfaces.
- Settings Central for operator-tunable configuration.
- Security Central for permission and policy decisions.
- Markdown-first memory under Allbert Home, plus local files/notes as a launch
  integration.
- Inspectable traces, events, objectives, jobs, and operator reports.
- Source-tree plugins and app surfaces, with StockSage as the main reference app.
- Public protocol surfaces with bounded, policy-checked exposure.

The packaged install and zero-click first run are what make Allbert runnable by
someone who is not me, including a non-developer, across the curl and Homebrew
paths. In v1.2, install, open, and chat is the primary experience: onboarding is
optional, an existing local or hosted provider is detected without hidden
inference, and an unavailable model leaves chat open with one honest repair path.

## What I Use It For

Allbert is a personal AI environment where the assistant can:

- answer and route local requests;
- remember information only through reviewable memory paths;
- resume longer-running work through objectives;
- expose app-specific workflows through reviewed plugins;
- show what settings, models, intents, jobs, and policies are active;
- connect to external tools only through explicit, policy-bounded actions.

This experiment supersedes my previous efforts on the same idea:
[go-llms](https://github.com/lexlapax/go-llms) and [go-llmspell](https://github.com/lexlapax/go-llmspell) in Go and
[rs-llmspell](https://github.com/lexlapax/rs-llmspell) in Rust.

Most of my attention goes to the boundary between useful autonomy and operator
control. Model output, plugin metadata, YAML, generated files, and app surfaces
do not grant authority by themselves. Authority comes from registered actions,
settings, policy checks, and confirmations.

## Built On

Allbert is implemented with Elixir, OTP, Phoenix LiveView, SQLite, and Jido.
Those details matter for contributors, but the promise to whoever is running it
is simpler: a supervised local assistant runtime with inspectable state, explicit
authority boundaries, and multiple operator surfaces over the same core.

## Where It Is Going

Allbert is moving toward a local assistant operating system: a place where
conversations, memory, settings, tools, background work, plugins, and app
surfaces share one authority model.

The roadmap is intentionally incremental, and it tracks my own use. Each release
proves a small contract in the real runtime, documents the boundary, validates
it, and only then makes that contract easier to reuse.

See [docs/plans/roadmap.md](docs/plans/roadmap.md) for the current milestone
sequence and [CHANGELOG.md](CHANGELOG.md) for shipped release details.

## Start Here

If you want to run Allbert on your own machine:

- [docs/operator/quickstart.md](docs/operator/quickstart.md): install, open, and
  chat — the canonical Allbert 1.2 first run.
- [docs/operator/workspace.md](docs/operator/workspace.md): the web workspace,
  panels, and operator-facing controls.
- [docs/operator/onboarding.md](docs/operator/onboarding.md): optional guided
  customization, provider setup, and repair after chat is available.
- [docs/operator/local-knowledge.md](docs/operator/local-knowledge.md): connect
  local files/notes and reviewed agent memory (the launch integration).
- [docs/operator/install.md](docs/operator/install.md): packaged install,
  upgrade, uninstall, and distribution-trust notes.
- [docs/operator/README.md](docs/operator/README.md): the complete task-based
  operator guide index.
- [docs/README.md](docs/README.md): the full project documentation map.
- [CHANGELOG.md](CHANGELOG.md) / [docs/plans/roadmap.md](docs/plans/roadmap.md):
  what has shipped and where the project is going next.

If you are reading or changing the code — your own fork included:

- [docs/design/architecture-diagrams.md](docs/design/architecture-diagrams.md):
  start here for the shape of the system — component map, how every surface
  reaches one runtime, a chat turn end to end, and the authority boundary every
  effect passes through.
- [DEVELOPMENT.md](DEVELOPMENT.md): local setup, commands, and verification gates.
- [AGENTS.md](AGENTS.md): repository rules for coding agents and agent-assisted
  work.
- [docs/developer/agent-context-map.md](docs/developer/agent-context-map.md):
  subsystem routing map for deeper work.
- [docs/developer/test-strategy.md](docs/developer/test-strategy.md): test lane
  taxonomy and release gate structure.
- [docs/adr/README.md](docs/adr/README.md): architectural decisions.

## Local Development

For working from source (the packaged product install path is in
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

## License

Allbert Assist is licensed under the [Apache License, Version 2.0](LICENSE).
Copyright 2026 Sandeep Puri. The [NOTICE](NOTICE) file carries the attribution
that Apache-2.0 requires redistributors to pass along.

Apache-2.0 matches the license of the stack Allbert is built on — Elixir and
Erlang/OTP are both Apache-2.0 — and it gives you an explicit patent grant
alongside the explicit "AS IS", no-warranty terms that match the no-promises
posture above.

Most known shipped components use permissive terms (including Apache-2.0, MIT,
BSD, and ISC) or public-domain material such as SQLite. One deliberately narrow
exception is Castore's Mozilla-derived CA bundle: Castore code is Apache-2.0,
while that generated PEM remains MPL-2.0 with file-scoped source-availability
and notice obligations. It does not relicense the larger Allbert work under
MPL. A GPLv2-**only** project cannot incorporate Apache-2.0 code; GPLv3 and
AGPLv3 can.

If you contribute, your contribution is licensed under the same terms — that is
Apache-2.0 §5, and there is no separate CLA.

The v1.2.3 binary will carry `LICENSE`, `NOTICE`, a deterministic reviewed
cross-target union, required license texts, exact source-availability metadata,
and a target-specific manifest. `allbert licenses` reads those packaged files
without starting the runtime or using the network. The inventory is explicitly
a best-effort account of known shipped components, not a universal SBOM or
legal-compliance guarantee; managed application/path/text seams, reviewed
inputs, and explicitly pinned provenance fail closed during the release build.
Source checkouts can verify catalog/report drift with
`mix allbert.licenses --check`.
