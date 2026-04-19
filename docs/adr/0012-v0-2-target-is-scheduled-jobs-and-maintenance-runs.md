# ADR 0012: v0.2 target is a daemonized local runtime with an internal job manager

Date: 2026-04-18
Status: Accepted

## Context

After v0.1 shipped, several plausible next directions existed: richer memory retrieval, scripting, broader integrations, more frontends, or scheduled/background execution. The project sources are still clear about the intended sequence: scheduled work comes next. What changed is the understanding of what must be built to deliver that well.

The old v0.2 plan treated jobs as another runtime surface plus OS-scheduler glue. That would add automation, but it would not create the daemon substrate that attachable clients, long-lived sessions, and lightweight internal services need. The daemon substrate is now understood to be part of the target itself, not optional scaffolding after the fact.

That does not change the order. It changes the architecture that should carry the next target.

## Decision

v0.2 will target **a daemonized local runtime with an internal job manager**.

- The next implementation focus is local recurring execution, not richer retrieval or scripting.
- v0.2 should introduce a daemon-capable host around the existing kernel.
- Scheduled jobs remain the main user-visible value unlock, but they should be owned by internal services rather than a standalone jobs runtime.
- The first shipped job value should be maintenance-oriented: memory review, summarization, and trace-oriented upkeep.
- Vector retrieval, scripting engines, retraining, and broader frontend work are explicitly deferred beyond this target.

## Consequences

**Positive**
- Follows the order already implied by the original note and the vision.
- Expands capability without abandoning the kernel-first architecture.
- Creates a natural place for memory maintenance and future compiled-memory workflows.
- Creates a shared runtime substrate for future channels and services.

**Negative**
- Adds daemon lifecycle, local protocol, and service supervision to the v0.2 scope.
- Defers other attractive directions such as RAG and scripting for at least one more release.

**Neutral**
- The jobs target can still carry a small generic prompt-job path, but the release emphasis remains maintenance-first.
- Future memory and retrieval work will inherit whatever scheduler/runtime shape v0.2 establishes.

## References

- [docs/vision.md](../vision.md)
- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
- [docs/notes/v0.2-target-2026-04-18.md](../notes/v0.2-target-2026-04-18.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
