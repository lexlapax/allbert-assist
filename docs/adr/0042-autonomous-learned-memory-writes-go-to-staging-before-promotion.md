# ADR 0042: Autonomous learned-memory writes go to staging before promotion

Date: 2026-04-20
Status: Accepted

## Context

Allbert already has raw memory file tools. That is not the same thing as permitting the agent to silently add new approved durable memory based on its own judgment. Once the assistant can infer lessons, preferences, and recurring facts across long-lived sessions, silent direct writes would make the durable memory corpus drift in ways the operator may never notice.

The durable-memory contract needs a rule stricter than "the tool exists."

## Decision

Autonomous learned-memory capture in v0.5 goes to staging first.

- Agent-authored candidate learnings are written under `~/.allbert/memory/staging/`.
- Promotion from staging into approved durable memory requires explicit operator approval through prompt-native review or CLI/operator commands.
- Autonomous reasoning does not directly write approved durable memory documents.

This ADR does **not** remove raw file tools:

- `write_memory` still exists as the explicit file-edit seam.
- Operators and skills can still make deliberate markdown edits through the existing policy envelope.
- The stricter rule applies to autonomous "I learned this" memory capture from agent reasoning.

## Consequences

**Positive**

- Durable memory stays reviewable and trustworthy.
- The system can learn proactively without silently mutating approved memory.
- Memory promotion gets the same explicitness posture that durable job mutation already has.

**Negative**

- The operator now has a review queue to manage.
- Some memory flows take two steps instead of one.

**Neutral**

- Future releases can make review UX richer without changing the staging-first rule.

## References

- [docs/plans/v0.05-curated-memory.md](../plans/v0.05-curated-memory.md)
- [ADR 0009](0009-v0-1-tool-surface-expansion-and-policy-envelope.md)
- [ADR 0027](0027-durable-schedule-mutations-require-preview-and-explicit-confirmation.md)
