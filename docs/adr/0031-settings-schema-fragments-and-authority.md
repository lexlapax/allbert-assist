# ADR 0031: Settings Schema Fragments And Authority

## Status

Proposed for v0.31 Runtime And UI-Substrate Consolidation
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

## Consequences

- v0.32 can render Settings Central inside `/workspace` from fragments.
- v0.33 theming can add theme/layout keys without editing a monolith.
- v0.34 dynamic-plugin policy keys can be declared without giving generated
  drafts authority.
- v0.35 can scaffold `schema_fragment/0` safely.

## Non-Goals

- No settings key rename.
- No defaults change.
- No separate `/settings` route decision; that belongs to v0.32.
- No settings-write permission relaxation.
