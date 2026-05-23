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

## Terminology

Three "registry"-like concepts are distinct and must not be conflated:

- **Action registry** (this ADR): the capability *metadata* the runtime action
  registry derives from each `use AllbertAssist.Action` module. "Capability
  metadata" here is action metadata, not a new registry artifact.
- **Extension registry** (ADR 0030): compiled app/plugin contributions (apps,
  surfaces, actions, skill roots, settings fragments, child specs).
- **Capability inventory / gap** (ADR 0021, ADR 0033): objective-owned
  acquisition vocabulary for missing capabilities.

## Relates To

- Refines: ADR 0006 (permission classes and safety floors), ADR 0007 (action
  runner boundary), ADR 0015 (app-scoped actions).
- Under: ADR 0026 facade discipline.
- Enables: v0.35 generator scaffolds `use AllbertAssist.Action`; v0.34 generated
  drafts use the same shape.
