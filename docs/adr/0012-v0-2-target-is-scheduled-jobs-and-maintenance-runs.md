# ADR 0012: v0.2 target is scheduled jobs and maintenance runs

Date: 2026-04-18
Status: Proposed

## Context

After v0.1 shipped, several plausible next directions existed: richer memory retrieval, scripting, broader integrations, more frontends, or scheduled/background execution. The project sources are unusually clear about the intended sequence.

The original note says that after the simple agent loop with shell/input/skills is working, the next step is scheduled and cron jobs. The vision says that once the early foundation is solid, the project can grow into scheduled jobs, broader integrations, richer memory retrieval, self-generated skills, and additional frontends.

That does not make every one of those equally urgent. It suggests an order: scheduled jobs come next because they reuse the shipped kernel foundation and create the runtime surface needed for maintenance work later.

## Decision

v0.2 will target **scheduled jobs and maintenance runs**.

- The next implementation focus is local recurring execution, not richer retrieval or scripting.
- v0.2 should introduce a jobs layer that can run recurring work on top of the existing kernel.
- The first shipped job value should be maintenance-oriented: memory review, summarization, and trace-oriented upkeep.
- Vector retrieval, scripting engines, retraining, and broader frontend work are explicitly deferred beyond this target.

## Consequences

**Positive**
- Follows the order already implied by the original note and the vision.
- Expands capability without changing the kernel-first architecture.
- Creates a natural place for memory maintenance and future compiled-memory workflows.

**Negative**
- Defers other attractive directions such as RAG and scripting for at least one more release.
- Adds product surface in the form of job definitions, schedules, and history that will need docs and tests.

**Neutral**
- The jobs target can still carry a small generic prompt-job path, but the release emphasis remains maintenance-first.
- Future memory and retrieval work will inherit whatever scheduler/runtime shape v0.2 establishes.

## References

- [docs/vision.md](../vision.md)
- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
