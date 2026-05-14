# Superseded: Post-v0.10 Implementation Tasks

Status: superseded by `docs/plans/roadmap.md` and the unified v0.xx plan
files.

This file is intentionally retained only as a verification marker until the
amalgamation is reviewed. Do not use it as an implementation source.

## Canonical Sources

- Overall sequencing and hard gates: `docs/plans/roadmap.md`
- Long-term architecture and StockSage workspace concepts:
  `docs/plans/allbert-jido-vision.md`
- Active milestone plans: `docs/plans/v0.11-plan.md` through
  `docs/plans/v0.28-plan.md`
- Phase 1 request flows:
  - `docs/plans/v0.11-request-flow.md`
  - `docs/plans/v0.12-request-flow.md`
- Binding decisions:
  - `docs/adr/0014-local-workspace-identity.md`
  - `docs/adr/0015-allbert-app-contract-and-surface-dsl.md`

## Why This File Can Go Away

The former two-track plan has been collapsed into one canonical v0.xx release
stream. The old M-D and M-AppContract labels remain only as historical aliases
inside the individual plan files, for continuity with the archived
`aiworkspace-plan.md`.

Phase 1 is now represented directly by:

- v0.11: Execution-Aware Intent, Approval Handoff, Resource Access
- v0.12: Local Workspace Identity and Conversation History

The rest of the former D-track is represented by v0.14, v0.15, v0.17, v0.19,
v0.21, v0.22, v0.24, v0.25, and v0.27. The hard canvas gate is recorded in
`roadmap.md`: v0.26 cannot start until v0.23 and v0.24 are complete.

After verification, this file can be deleted without losing implementation
guidance.
