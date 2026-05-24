# ADR 0036: Templated Creation And Pattern Registry

## Status

Proposed for v0.37 Templated Creation (`docs/plans/v0.37-plan.md`). Builds on the
v0.36 generation engine (ADR 0032/0033/0035) and the plugin/app contracts
(ADR 0015/0017).

## Context

v0.36 gives Allbert a dynamic, LLM-driven generation/integration engine: detect
a capability gap, author code/config, trial it in an OS sandbox, and — after the
warning gate and operator confirmation — integrate it live. That is powerful but
open-ended and higher-risk. Most creation, though, follows well-known patterns:
a plugin, an app, an LLM-backed tool, or a future "templated code" pattern. Those
should be first-class, deterministic, and low-risk — and reachable both by a
developer (Mix tasks) and an operator (a guided workspace flow). v0.37 records
how templated creation is structured and how it reuses v0.36's safety.

## Decision

### 1. A `TemplatePattern` registry, not hard-coded generators
Creation patterns are vetted, parameterized skeletons registered through a
`TemplatePattern` behaviour and discovered via `AllbertAssist.Templates`. A
pattern declares a parameter schema, a reviewed file set, and the proven
contract shapes it targets. Resolution is deterministic parameter substitution
into reviewed files — not free LLM authoring. Shipped patterns: plugin, app,
LLM tool; future patterns register through the same behaviour without a new
milestone. Templates and parameters are metadata and grant no authority.

### 2. Two output modes
- **Developer scaffold (default, safe):** write inert source under
  `./plugins/<name>/` for human review, compile, and test. No live integration,
  no trust, no compile-path change, no permission grant.
- **Operator templated creation:** a parameterized template runs through the
  exact v0.36 gated path — OS sandbox trial + full warning gate + operator
  confirmation + the audited, reversible loader (ADR 0032/0035). v0.37 adds no
  new isolation, hot-load, or integration authority.

### 3. Developer and operator surfaces
Mix tasks (`mix allbert.gen.plugin` / `gen.app` / `gen.tool` / `gen.<pattern>`,
`validate_app`) serve developers. A `/workspace` Canvas creation surface (a
`workspace:create` destination) serves operators: template gallery → parameter
form → preview → validate → developer-scaffold or operator live integration. The
surface is view/compose only; every effectful step runs through registered
actions and Security Central.

### 4. Reuse v0.36 safety
Templated live integration is exactly the v0.36 gated path; it cannot bypass the
sandbox trial, the warning gate, or operator confirmation. Determinism plus
vetted templates make this the lower-risk creation path relative to v0.36's
open-ended LLM generation.

## Consequences

- Common creation patterns become one-command (developer) or one-flow (operator)
  with first-run validation.
- The pattern registry is the extension point for future "templated code"
  patterns and for the v0.36 deterministic-output contract.
- Security evals must prove template parameter injection, traversal, authority
  bypass, and ungated/unconfirmed templated integration fail closed.

## Non-Goals

- No remote template marketplace or remote code-bearing templates.
- No new isolation/hot-load/integration authority beyond v0.36.
- No autonomous creation; a developer/operator initiates every run and live
  integration is operator-confirmed.
- No multi-language templates beyond Elixir/OTP (parked).

## Relates To

- Builds on: ADR 0015 (app/surface), ADR 0017 (plugin contract), ADR 0027
  (`AllbertAssist.Action`), v0.27–v0.35 contract shapes.
- Reuses: ADR 0032 (sandbox + gated integration), ADR 0033 (trust tiers), ADR
  0035 (generation engine + loader).
- Constrained by: ADR 0006 (Security Central) and ADR 0009 (BEAM is not an OS
  boundary).
