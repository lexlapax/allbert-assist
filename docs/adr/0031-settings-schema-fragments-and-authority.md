# ADR 0031: Settings Schema Fragments And Authority

## Status

Accepted in v0.31 M8 Runtime And UI-Substrate Consolidation
(`docs/plans/archives/v0.31-plan.md`).

Enforcement note (v0.58, 2026-06-24): see the ADR 0004 v0.58 enforcement note —
every operator-tunable setting is a registered schema-fragment key read through
Settings Central; surfaces must not keep surface-local config or read
`Settings.Store`/`Application.get_env` ad-hoc for tunable values. A CI guard
enforces this. Cross-surface settings reads route through the ADR 0070 read-only
action layer (ADR 0073).

v1.4 amendment (operator decision 2026-08-06): ADR 0098 distributes fragment
ownership to named packs without distributing Settings Central authority.
`AllbertAssist.Settings.Schema` remains the compatibility facade; callers do not
need to know which application owns a fragment.

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

ADR 0098 extends that assembly rule: a compiled pack owns and registers its
fragment, while Settings Central remains responsible for deterministic
composition, duplicate-key rejection, provenance, validation, reads, writes,
secrets, migration, and audit. Moving a fragment between applications is an
ownership change only. It does not rename a key, change its default or
validation, rewrite stored data, or alter its schema version unless ADR 0046's
non-additive migration rules independently require that change.

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
does not constitute a second authority.

v1.4 retires that facade by direct caller migration (operator decision
2026-08-06). Every caller invokes `AllbertAssist.Security` at the same logical
decision point and retains its existing capability, permission, confirmation,
context, and action-local control flow. In particular, authorization does not
move into the central parameter validator or become an implicit Runner side
effect. The only intentional decision-envelope change is `decision.source`:
after direct migration it names `AllbertAssist.Security`, not the retired
`PermissionGate` facade. Authorization outcome and all other decision semantics
must remain at parity.

Retirement is therefore independent of ADR 0065 parameter validation. It lands
only after a complete call-site inventory, red-first caller tests, and Security
eval coverage prove that no decision point was skipped or widened. Resource
grants continue to perform scope/expiry/revocation matching against an
already-resolved decision rather than re-authorizing.

## Relates To

- Refines: ADR 0006 (Security Central as the permission authority) and the
  Settings Central foundation.
- Under: ADR 0026 facade discipline.
- Amended by: ADR 0098 (pack-owned fragments composed by Settings Central).
- Clarified by: ADR 0065 (parameter validation is not authorization).
- Enables: v0.32 workspace Settings Central panel, v0.35 theme/layout keys,
  v0.36 sandbox policy keys, v0.37 dynamic-plugin policy keys, and v0.38
  `schema_fragment/0` scaffolding.
