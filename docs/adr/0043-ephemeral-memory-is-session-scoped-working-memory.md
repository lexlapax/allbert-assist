# ADR 0043: Ephemeral memory is session-scoped working memory

Date: 2026-04-20
Status: Accepted

## Context

Long-lived daemon sessions, scheduled jobs, and sub-agents all benefit from a working-memory layer that is neither:

- approved durable memory, nor
- hidden restart-durable transcripts.

Without an explicit ephemeral-memory rule, transient task state tends to leak into durable memory or to disappear in ad hoc ways.

## Decision

v0.5 introduces ephemeral memory as session-scoped working memory.

- It is attached to the daemon session, not the operator's entire profile.
- It survives channel detach/reattach while the session is alive.
- It is lost on daemon restart.
- It may update multiple times during one turn.
- It is not written to disk in v0.5.

Ephemeral memory is for:

- temporary task state
- pending approvals
- recent tool output summaries
- sub-agent return summaries
- short-lived coordination state

It is not a substitute for durable memory.

## Consequences

**Positive**

- The runtime gets a real working-memory layer for coordination.
- Durable memory remains smaller and more intentional.
- Channels and jobs can use the same concept of session working state.

**Negative**

- Operators may expect more continuity than v0.5 intentionally provides across daemon restarts.

**Neutral**

- Future releases may choose to persist some session state, but only as a separate explicit subsystem.

## References

- [docs/plans/v0.05-curated-memory.md](../plans/v0.05-curated-memory.md)
- [ADR 0003](0003-memory-files-are-durable-chat-history-is-not.md)
- [ADR 0021](0021-kernel-multiplexes-sessions-shared-runtime-per-session-state.md)
