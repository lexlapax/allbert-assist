# ADR 0027: Durable schedule mutations require preview and explicit confirmation

Date: 2026-04-19
Status: Accepted

## Context

Prompt-native job tools make it possible for an interactive assistant session to create or modify recurring work. That is powerful, but it is also a durable mutation to the user's automation state.

Unlike a one-shot tool call, a schedule mutation can:

- create recurring future behavior
- change when work runs
- change the model or tools used by unattended jobs
- overwrite an existing named job

That makes job creation and mutation closer to editing a durable automation artifact than to answering a transient question.

## Decision

Durable schedule mutations require a preview and explicit user confirmation.

This applies to:

- creating a new job
- updating an existing job definition
- pausing or resuming a job
- removing a job

The conversational flow should:

1. Produce a normalized preview of the intended durable change.
2. Ask for explicit confirmation before persisting it.
3. Persist through `JobManagerService` only after confirmation.

The preview should show enough detail to be auditable:

- job name
- description
- schedule
- timezone
- model override when present
- attached skills
- allowed tools
- report policy
- whether the mutation creates, updates, pauses, resumes, or removes a job

## Consequences

**Positive**
- Preserves the explicit-consent posture that already exists for risky durable actions.
- Makes conversational scheduling auditable rather than magical.
- Reduces the chance of accidental recurring automation caused by ambiguous user wording.

**Negative**
- Adds one more interaction step for automation-heavy users.
- Requires a normalized preview renderer and duplicate/update semantics.

**Neutral**
- This ADR does not require a particular text format for the preview, only that the change be clear and explicit before persistence.
- Non-durable inspection operations like `list_jobs` and `get_job` do not require confirmation.

## References

- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0026](0026-interactive-sessions-expose-first-class-daemon-backed-job-management-tools.md)
