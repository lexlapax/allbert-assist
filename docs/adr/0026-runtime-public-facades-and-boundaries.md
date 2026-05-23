# ADR 0026: Runtime Public Facades And Boundaries

## Status

Proposed for v0.31 Runtime And UI-Substrate Consolidation
(`docs/plans/v0.31-plan.md`).

## Context

Allbert has grown several runtime substrates quickly: actions, settings,
plugins, apps, workspace surfaces, traces, audits, memory, confirmations,
objectives, and StockSage. Many modules are still used directly by callers
even when a higher-level context or facade exists. That makes later UI,
dynamic-plugin, and generator work likely to depend on private implementation
details.

## Decision

v0.31 will document and enforce a public/internal boundary for runtime-facing
subsystems before moving code. Each consolidation milestone starts by naming:

- the public facade callers should use;
- internal helpers that may change without downstream coordination;
- compatibility shims and their retirement criteria;
- tests or compile-time checks that prove callers use the public facade.

This ADR does not make OTP supervision, BEAM processes, or child processes a
security boundary. Authority still comes from registered actions, Security
Central, Settings Central, confirmations, and audited runtime contexts.

## Consequences

- Downstream v0.32-v0.35 plans can target stable facades instead of incidental
  modules.
- Deletions are safer because compatibility shims have owners and exit
  criteria.
- The generator must scaffold public facades only.

## Non-Goals

- No route changes.
- No user-visible behavior changes.
- No dynamic module loading.
- No permission or confirmation policy changes.
