# ADR 0041: Plan/Build Mode And Operator Workflow YAML

## Status

Proposed for v0.45 Plan/Build Mode And Operator Workflow YAML
(`docs/plans/v0.45-plan.md`).

## Context

Objective Runtime already stores durable multi-step work. v0.45 exposes that
substrate to operators as Plan/Build mode and adds declarative workflow YAML
for repeatable objectives.

## Decision

- Plan/Build is a workspace/channel surface over Objective Runtime.
- Workflow YAML is declarative data that produces objective steps.
- YAML is validated by an explicit schema; unknown keys fail closed.
- YAML never executes scripts, shell, package managers, or model-generated code.
- Every produced step executes through `Actions.Runner.run/3`, Security
  Central, confirmations, traces, and audits.
- `objective_id`, `step_id`, advisory output, and plan previews are never
  authority.

## Consequences

Operators can review, edit, and approve multi-step work without creating a
parallel execution engine. Existing Objective Runtime and action boundaries
remain the only sanctioned substrate.

## Non-Goals

- No autonomous plan approval.
- No lowering action-level confirmation floors.
- No private workflow scheduler or objective store.

## Amendment (post-v0.37 planning pass): Workflow YAML Location

Workflow YAML files live under `<ALLBERT_HOME>/workflows/<workflow-id>.yaml`.
The `<workflow-id>` is a deterministic operator-chosen slug
(`^[a-z0-9][a-z0-9_-]*$`) used for cross-reference; collisions fail the
import path.

Discovery is on-demand: the runtime reads the YAML file when an operator
references the workflow id (e.g., "run workflow nightly-briefing") and
expands it into objective steps at request time. No scanning, no autoload,
no compilation, no execution outside of objective-step expansion.

Workflow YAML files are inert data. The runtime never executes them. The
expansion path validates the schema (unknown keys fail closed), produces
objective step attrs, and hands those attrs to the v0.24 objective engine
through the normal frame/propose path.

Operators may version-control `<ALLBERT_HOME>/workflows/` separately from
the rest of Allbert Home if they wish; v0.51 export/import preserves the
directory.
