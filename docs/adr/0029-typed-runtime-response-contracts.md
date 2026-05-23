# ADR 0029: Typed Runtime Response Contracts

## Status

Proposed for v0.31 Runtime And UI-Substrate Consolidation
(`docs/plans/v0.31-plan.md`).

## Context

Actions, intent routing, objectives, confirmations, and UI surfaces currently
consume several map-shaped response variants. The lack of a single response
contract makes workspace panels and generated actions more likely to inspect
incidental keys.

## Decision

Allbert will add a typed runtime response contract for common outcomes:

- completed;
- needs confirmation;
- denied;
- advisory;
- error;
- unsupported or unavailable capability.

The contract should be convenient for actions and objective steps while still
rendering the same CLI and LiveView behavior that operators see today.

## Consequences

- v0.32 panels can render action/objective status without special cases.
- v0.34 capability-gap and sandbox-trial reports can attach structured
  diagnostics.
- v0.35 generated actions can return the approved response shape.

## Non-Goals

- No copy rewrite unless implementation records a specific request-flow update.
- No permission change.
- No transport protocol change.
