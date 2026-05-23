# ADR 0027: Allbert Action DSL And Capability Registry

## Status

Proposed for v0.31 Runtime And UI-Substrate Consolidation
(`docs/plans/v0.31-plan.md`).

## Context

Runtime-facing actions currently use `Jido.Action` directly and repeat Allbert
metadata, permission checks, response helpers, registry wiring, and app-scope
rules. Private Jido command modules inside agents also use Jido actions but
must not become Allbert capability actions.

## Decision

Allbert will add `use AllbertAssist.Action` as the approved shape for
runtime-facing, registered capability actions. It remains a thin wrapper over
Jido action behavior, but it owns Allbert-specific metadata:

- stable action id;
- permission class and safety floor;
- optional app ownership and active-app requirements;
- capability metadata for registries, intent, generator docs, and security
  review;
- response helper integration;
- compile-time validation where feasible.

Private Jido command modules used inside state-machine agents remain private
and must not appear in the Allbert action registry or intent candidates.

## Consequences

- Generated and handwritten actions have one shape.
- The action registry can derive capability metadata from the module instead
  of requiring several hand-edited locations.
- Security Central remains the authority; metadata declares intent but never
  grants permission.

## Non-Goals

- No replacement of Jido.
- No automatic permission grants.
- No registration of private agent commands as public actions.
