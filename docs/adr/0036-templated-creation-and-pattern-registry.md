# ADR 0036: Templated Creation And Pattern Registry

## Status

Proposed for v0.38 Templated Creation (`docs/plans/v0.38-plan.md`). Builds on
the v0.36 sandbox/gate runner (ADR 0037), the v0.37 generation/live-loader
engine (ADR 0032/0033/0035), and the plugin/app contracts (ADR 0015/0017).

## Context

v0.37 gives Allbert a dynamic, LLM-driven generation/integration engine. That
is powerful but open-ended and higher-risk. Most creation follows well-known
patterns: a plugin, app, LLM-backed tool, scheduled/chron flow, objective
workflow, or future reviewed code pattern. Those should be deterministic and
reachable both by developers through Mix tasks and by operators through a
guided workspace flow.

## Decision

### 1. A `TemplatePattern` registry

Creation patterns are vetted, parameterized skeletons registered through a
`TemplatePattern` behaviour and discovered via `AllbertAssist.Templates`. A
pattern declares a parameter schema, reviewed file set, output roots, target
contract shapes, optional validation/gate profile, and whether live integration
is supported. Resolution is deterministic parameter substitution into reviewed
files, not free LLM authoring. If a renderer such as EEx is used, only shipped
reviewed templates are evaluated; operator/developer parameters are escaped and
normalized data, never executable template code.

Templates and parameters are metadata and grant no authority.

### 2. Two output modes

- **Developer scaffold:** write inert source under `--target`, defaulting to
  `./plugins/<name>/`, for human review, compile, and test. Existing target
  roots are not overwritten without explicit `--force` and preview/diff. No
  live integration, trust, compile-path change, route, permission grant, or
  schedule enablement.
- **Operator templated creation:** render a template, run validation and the
  v0.36 sandbox gate, then optionally integrate through the v0.37
  operator-confirmed loader. v0.38 adds no new sandbox or integration
  authority.

### 3. Developer and operator surfaces

Mix tasks (`mix allbert.gen.plugin`, `gen.app`, `gen.tool`, `gen.flow`,
`gen.<pattern>`, `validate_app`) serve developers. A `/workspace` Canvas
creation surface (`workspace:create`) serves operators: template gallery →
parameter form → preview → validate → developer scaffold or operator live
integration. The surface is view/compose only; every effectful step runs
through registered actions and Security Central.

Parameter normalization produces reviewed slugs, module namespaces, app ids,
destination ids, schedule ids, and paths. Raw params never create atoms
directly. Generated v0.35 theme/snippet/layout stubs are inert and disabled by
default.

### 4. Shipped patterns

v0.38 ships reviewed templates for:

- plugin;
- app;
- LLM tool;
- scheduled/chron flow;
- objective workflow.

Future patterns register through the same behaviour without granting authority.

### 5. Settings Central owns the create surface

The operator `workspace:create` destination is gated by a default-off
`templates.create.enabled` switch, with `templates.allowed_patterns` bounding the
gallery. Developer Mix-task scaffolds are inert and dev-time and need no runtime
settings. Operator live integration adds no new authority: it additionally
requires the v0.37 `dynamic_codegen.*` switches and the v0.36
`sandbox.elixir.enabled` gate, and routes through registered actions and Security
Central like any effectful work.

## Consequences

- Common creation patterns become one-command or one-flow with first-run
  validation.
- The pattern registry is the extension point for future templated code.
- Security evals must prove template parameter injection, traversal, authority
  bypass, overwrite denial, scheduled-flow escalation, and
  ungated/unconfirmed integration fail closed.

## Non-Goals

- No remote template marketplace or remote code-bearing templates.
- No new isolation, hot-load, or integration authority beyond v0.36/v0.37.
- No autonomous creation from traces.
- No dependency/migration/NIF additions.
- No multi-language templates beyond Elixir/OTP.
- No overwrite of existing user/project files without explicit force and
  preview/diff.

## Relates To

- Builds on: ADR 0015, ADR 0017, ADR 0027, and v0.27-v0.35 contract shapes.
- Reuses: ADR 0037 (sandbox), ADR 0032/0033/0035 (dynamic generation and gated
  loader).
- Constrained by: ADR 0006 and ADR 0009.
