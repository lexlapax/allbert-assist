# ADR 0015: Scheduled jobs fail closed on interactive actions

Date: 2026-04-18
Status: Proposed

## Context

The REPL can ask the user for confirmation or more input in the middle of a turn. A scheduled job usually cannot. There may be no human present, no terminal attached, and no acceptable delay while waiting for a response.

That creates a policy choice. The job runtime could auto-allow actions it would normally confirm, silently skip blocked steps, or fail closed and record why the run stopped. The first two options are attractive for "smooth automation," but they also create the highest risk of silent unsafe behavior or silent partial execution.

## Decision

Scheduled jobs fail closed on interactive actions unless explicit non-interactive policy already permits the step.

- Confirmation requests deny by default in scheduled runs unless the relevant action is already explicitly allowed by job policy or global policy.
- `request_input` is unavailable in scheduled runs and should resolve as cancelled / unavailable rather than hanging.
- Job history should record the reason a run stopped when it encounters missing input or denied confirmation.
- Bundled maintenance jobs should be designed to avoid interactive requirements entirely.
- Scheduled runs cannot create, edit, pause, resume, or remove other scheduled jobs while they are executing.
- Output policy should be explicit. At minimum, the design should support `always`, `on_failure`, and `on_anomaly` style reporting rather than assuming every successful run should speak up.

## Consequences

**Positive**
- Preserves the security posture established in v0.1 instead of quietly weakening it for automation.
- Prevents scheduled runs from hanging indefinitely waiting for a human who is not there.
- Makes job failures diagnosable instead of silent.
- Reduces the risk of runaway self-scheduling loops or noisy "everything is fine" spam.

**Negative**
- Some recurring tasks will need extra configuration before they can run unattended.
- Jobs may fail more often during setup until their required policy is explicit.
- Quiet-success and anomaly-only policies add one more reporting dimension to document and test.

**Neutral**
- Future versions may add richer non-interactive policy profiles, but the default remains fail-closed.
- A separate queue-for-review UX could be added later without changing this default rule.
- This ADR does not decide delivery targets; it only decides that unattended runs must not block on a human or self-modify the scheduler.

## References

- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
