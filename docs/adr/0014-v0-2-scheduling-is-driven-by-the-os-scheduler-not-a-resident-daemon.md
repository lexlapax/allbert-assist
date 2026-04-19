# ADR 0014: v0.2 scheduling is owned by the daemon's internal job manager

Date: 2026-04-18
Status: Proposed

## Context

There are two broad ways to make scheduled jobs happen in v0.2:

1. let the daemon own a lightweight internal scheduler and job manager;
2. let the operating system scheduler invoke Allbert when a job is due.

The earlier v0.2 plan chose the second model. After revisiting the intended kernel shape, that is no longer the right fit. If Allbert is going to support attachable channels and lightweight internal services, it already needs a long-lived local daemon host. Once that exists, pushing scheduling back out to OS cron weakens the architecture rather than simplifying it.

## Decision

v0.2 scheduling will be **owned by the daemon's internal job manager**.

- The daemon runs the scheduler loop itself.
- Job definitions, mutable job state, and run metadata persist locally.
- The jobs client talks to the daemon-owned job manager rather than becoming its own scheduler host.
- OS service management may come later, but OS cron is not the primary scheduler in v0.2.
- Boot-time service install and management are explicitly deferred.

## Consequences

**Positive**
- Keeps scheduling aligned with the daemon-capable runtime architecture.
- Gives Allbert one internal scheduling model across platforms.
- Creates a cleaner base for future maintenance, background work, and richer services.

**Negative**
- Adds a scheduler loop and persistent job state to the daemon's scope.
- Means scheduled work only runs while the user daemon is up in v0.2.

**Neutral**
- A future version can still add boot-time service install or tighter OS integration if the user-daemon model proves too limiting.
- Cross-platform concerns shift from OS cron documentation to local IPC and daemon operations.

## References

- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
- [docs/notes/v0.2-target-2026-04-18.md](../notes/v0.2-target-2026-04-18.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
