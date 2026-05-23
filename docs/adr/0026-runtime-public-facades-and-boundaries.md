# ADR 0026: Runtime Public Facades And Boundaries

## Status

Accepted in v0.31 Runtime And UI-Substrate Consolidation
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

Implementation note: v0.31 introduced `AllbertAssist.Boundary` and
`docs/developer/runtime-boundary-map.md`, then moved each consolidation seam
behind the public facades named by ADR 0027-0031.

## Consequences

- Downstream v0.32-v0.36 plans can target stable facades instead of incidental
  modules.
- Deletions are safer because compatibility shims have owners and exit
  criteria.
- The generator must scaffold public facades only.

## Non-Goals

- No route changes.
- No user-visible behavior changes.
- No dynamic module loading.
- No permission or confirmation policy changes.

## Relates To

- Applied by: ADR 0027, ADR 0028, ADR 0029, ADR 0030, and ADR 0031 — each v0.31
  consolidation ADR names its public facade, internal helpers, and shim
  retirement criteria under this discipline.
- Builds on: ADR 0007 (Jido-native internal runtime boundaries).
- Authority unchanged: this ADR is not a security boundary; permission authority
  remains ADR 0006 (Security Central).
- Enables: v0.32-v0.36 target stable facades instead of incidental modules.
