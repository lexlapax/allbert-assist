# ADR 0028: Shared Runtime Substrates

## Status

Proposed for v0.31 Runtime And UI-Substrate Consolidation
(`docs/plans/v0.31-plan.md`).

## Context

Path resolution, redaction, audit, trace, and persistence logic are used by
many subsystems. Several local helper variants exist because features landed
incrementally. The v0.34 dynamic-plugin trial path will need especially clear
substrates for Allbert Home roots, redacted output, sandbox audit events, and
copy-in/copy-out persistence.

## Decision

v0.31 will consolidate these helpers behind documented runtime facades:

- Allbert Home path resolution and root creation;
- redaction for CLI, LiveView, traces, audits, Resource Access, StockSage, and
  sandbox-trial reports;
- audit event writing and vocabulary;
- trace writing and lifecycle metadata;
- hybrid persistence helpers where SQLite metadata and YAML/markdown bodies
  need one durable contract.

Existing on-disk formats and event vocabulary must remain stable unless a
separate migration plan is accepted.

## Consequences

- v0.32 workspace UI, v0.33 theming, and v0.34 dynamic trials reuse one path
  and redaction model.
- Audit and trace behavior becomes easier to test consistently.
- Data format changes remain out of scope for the consolidation release.

## Non-Goals

- No migration.
- No weakening of redaction.
- No new sandbox backend by itself.
