# ADR 0014: v0.2 scheduling is driven by the OS scheduler, not a resident daemon

Date: 2026-04-18
Status: Proposed

## Context

There are two broad ways to make scheduled jobs happen:

1. build an always-running internal scheduler daemon into Allbert;
2. let the operating system scheduler invoke Allbert when a job is due.

The original note leans clearly toward the second model by calling out cron or OS-level scheduled jobs. For a technical local-first tool, that is also the smaller and more auditable approach. A resident daemon would add lifecycle management, background process semantics, shutdown/restart behavior, and new failure modes before the product has even shipped its first automation layer.

## Decision

v0.2 scheduling will be **OS-scheduler-driven**.

- Allbert should expose commands such as `run <job-id>` and `run-due`.
- Those commands should be documented and stable enough to be scheduled by macOS `launchd`, Linux `cron` / `systemd` timers, and Windows Task Scheduler.
- v0.2 does not add a resident internal scheduler daemon.
- Scheduler integration is documented for technical users rather than hidden behind a packaged background service.
- Platform-specific installer helpers may come later, but the scheduler command interface itself is part of the cross-platform v0.2 contract.

More concretely, v0.2's support target is:

- macOS: documented `launchd` scheduling path
- Linux: documented `cron` and `systemd` timer path
- Windows: documented Task Scheduler path

This means Windows is included in the scheduler-interface contract for v0.2 rather than deferred to a later release. What remains deferred is convenience around installing or generating those scheduler entries automatically.

## Consequences

**Positive**
- Keeps the implementation smaller, more inspectable, and more local-first.
- Matches the technical-user audience already chosen for the current product phase.
- Avoids inventing daemon management before the jobs model itself is proven valuable.
- Gives the jobs frontend one portable command contract across macOS, Linux, and Windows.

**Negative**
- OS-scheduler setup is less polished than a built-in background service.
- Cross-platform documentation becomes part of the product surface earlier.
- Windows support adds one more scheduler surface to test and document in v0.2.

**Neutral**
- A future version can still add a resident scheduler if the OS-driven model proves too limiting.
- The jobs frontend needs a stable command-line contract because the OS scheduler will depend on it.

## References

- [docs/notes/origin-2026-04-17.md](../notes/origin-2026-04-17.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
