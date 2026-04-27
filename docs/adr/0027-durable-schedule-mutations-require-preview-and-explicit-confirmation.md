# ADR 0027: Durable schedule mutations require preview and explicit confirmation

Date: 2026-04-19
Status: Accepted

> **v0.14.3 amendment**: mutating conversational schedule requests may be
> drafted by the schema-bound intent router, but they must still enter the
> daemon-backed job mutation tool before any prose confirmation. The structured
> preview/confirmation surface remains the only approval path; a model asking
> "Shall I proceed?" in plain text is not an acceptable durable-change flow.

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

1. Call the relevant job mutation tool (`upsert_job`, `pause_job`,
   `resume_job`, or `remove_job`) for the durable schedule mutation.
2. Produce a normalized preview of the intended durable change.
3. Ask for explicit confirmation before persisting it.
4. Persist through `JobManagerService` only after confirmation.

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

- [docs/plans/v0.02-scheduled-jobs.md](../plans/v0.02-scheduled-jobs.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0026](0026-interactive-sessions-expose-first-class-daemon-backed-job-management-tools.md)
