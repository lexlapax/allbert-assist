# ADR 0028: Shared Runtime Substrates

## Status

Accepted in v0.31 M3-M4 Runtime And UI-Substrate Consolidation
(`docs/plans/archives/v0.31-plan.md`).

## Context

Path resolution, redaction, audit, trace, and persistence logic are used by
many subsystems. Several local helper variants exist because features landed
incrementally. The v0.36 Elixir/OTP sandbox and v0.37 dynamic-plugin trial path
will need especially clear substrates for Allbert Home roots, redacted output,
sandbox audit events, and copy-in/copy-out persistence.

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

- v0.32 workspace UI, v0.33 intent handoff, v0.34 workspace UX refresh,
  v0.35 theming, v0.36 sandboxing, v0.37 dynamic trials, and v0.38 generator
  work reuse one path and redaction model.
- Audit and trace behavior becomes easier to test consistently.
- Data format changes remain out of scope for the consolidation release.

## v0.31 Implementation Notes

- M3 introduced `AllbertAssist.Runtime.Paths` and
  `AllbertAssist.Runtime.Redactor` as behavior-preserving facades.
- M4 introduced `AllbertAssist.Runtime.Audit`,
  `AllbertAssist.Runtime.Persistence`, and `AllbertAssist.Runtime.Trace`.
  Existing audit markdown, trace markdown, workspace YAML bodies, Fragment
  body codecs, and SQLite metadata formats remain unchanged.

## Non-Goals

- No migration.
- No weakening of redaction.
- No new sandbox backend by itself.

## Relates To

- Applies ADR 0026's facade discipline to five named substrates: paths,
  redaction, audit, trace, and persistence.
- Builds on: the Allbert Home / `AllbertAssist.Paths` model and ADR 0006
  (Security Central redaction).
- Enables: ADR 0037 (v0.36 sandbox paths), ADR 0032 / ADR 0033 (v0.37
  sandbox-trial paths, redaction, and audit), and v0.32 through v0.38 reuse of
  one path and redaction model.
