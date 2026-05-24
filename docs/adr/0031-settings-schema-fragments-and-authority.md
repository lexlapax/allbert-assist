# ADR 0031: Settings Schema Fragments And Authority

## Status

Accepted in v0.31 M8 Runtime And UI-Substrate Consolidation
(`docs/plans/v0.31-plan.md`).

## Context

Settings Central is the operator configuration authority, but its schema has
grown into a large monolithic module. Apps, plugins, channels, workspace,
security, themes, and dynamic-plugin drafts need a way to own their schema
fragments without bypassing Settings Central.

## Decision

Allbert will introduce a settings-fragment contract. Core contexts, compiled
apps, and compiled plugins may register fragments that declare keys, defaults,
types, validation, descriptions, secrecy, and UI grouping metadata.

Settings Central remains the only runtime-facing write authority. Fragment
metadata does not grant permission, expose secrets, change security floors, or
enable capabilities by itself.

Implementation note: M8 introduced `AllbertAssist.Settings.Fragment` and
`AllbertAssist.Settings.Fragments`. `AllbertAssist.Settings.Schema` remains the
compatibility facade for existing callers, but schema/default/safe-write
assembly now flows through registered core/app/plugin fragments.

## Consequences

- v0.32 can render Settings Central inside `/workspace` from fragments.
- v0.35 theming can add theme/layout keys without editing a monolith.
- v0.36 sandbox policy keys and v0.37 dynamic-plugin policy keys can be declared
  without giving generated drafts authority.
- v0.38 can scaffold `schema_fragment/0` safely.

## Non-Goals

- No settings key rename.
- No defaults change.
- No separate `/settings` route decision; that belongs to v0.32.
- No settings-write permission relaxation.

## Authority Consolidation

Security Central (`AllbertAssist.Security.authorize/2`) is the sole runtime
authority for permission decisions. The compatibility
`AllbertAssist.Security.PermissionGate` shim delegates to Security Central and
remains supported for current live callers. It is not deleted in M8 because
there are still many action, objective, and plugin callers. Retirement requires
a later caller-migration parity pass with security eval coverage. Resource
grants then perform scope/expiry/revocation matching against an
already-resolved decision rather than re-authorizing, removing the redundant
per-request authorization paths. This is a security-gated change: retirement
lands only with parity tests and eval coverage, not as casual cleanup.

## Relates To

- Refines: ADR 0006 (Security Central as the permission authority) and the
  Settings Central foundation.
- Under: ADR 0026 facade discipline.
- Enables: v0.32 workspace Settings Central panel, v0.35 theme/layout keys,
  v0.36 sandbox policy keys, v0.37 dynamic-plugin policy keys, and v0.38
  `schema_fragment/0` scaffolding.
