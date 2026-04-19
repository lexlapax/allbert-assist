# ADR 0025: v0.2 daemon shutdown is bounded graceful and job failures are surfaced

Date: 2026-04-19
Status: Proposed

## Context

Once the daemon owns recurring work, two operator questions become unavoidable:

1. what does `stop` mean when jobs or turns are still running?
2. how does a user notice that a scheduled run failed without constantly reading JSONL files?

Answering both only with "check the logs later" would technically function, but it would make the daemon feel brittle and disconnected from the interactive experience. At the same time, v0.2 is still an in-process service-oriented daemon, not a fully isolated supervisor with strong draining guarantees.

## Decision

v0.2 daemon shutdown is **bounded graceful**, and scheduled job failures must be surfaced both durably and interactively.

- `daemon stop` stops new accepts and new scheduled launches first.
- The daemon then waits up to a bounded timeout for in-flight turns and scheduled runs.
- Work still running after that timeout is cancelled as the daemon exits.
- Interrupted scheduled runs are recorded as distinct non-success outcomes in run history and failure logs.
- Scheduled job failures are also broadcast as structured notifications to attached interactive clients so the operator can notice them during normal REPL use.
- `jobs status` must show recent outcome/failure information, not just schedule metadata.

## Consequences

**Positive**
- Makes daemon operations legible to an end user.
- Keeps shutdown semantics honest without pretending v0.2 is a fully isolated supervisor.
- Gives both durable and live visibility into recurring-job failures.

**Negative**
- Requires task tracking, cancellation, and notification plumbing in the daemon.
- Adds more closeout work than a minimal "just exit" daemon would.

**Neutral**
- The timeout value can stay simple in v0.2 and become configurable later if needed.
- Future versions can improve isolation without invalidating the bounded-graceful model.

## References

- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
- [ADR 0014](0014-v0-2-scheduling-is-owned-by-the-daemon-job-manager.md)
- [ADR 0019](0019-v0-2-services-are-supervised-in-process-tasks-with-future-subprocess-seams.md)
