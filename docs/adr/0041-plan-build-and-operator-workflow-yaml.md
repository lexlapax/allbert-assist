# ADR 0041: Plan/Build Mode And Operator Workflow YAML

## Status

Proposed for v0.44 Plan/Build Mode And Operator Workflow YAML
(`docs/plans/v0.44-plan.md`).

## Context

Objective Runtime already stores durable multi-step work. v0.44 exposes that
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
