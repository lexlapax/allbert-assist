# ADR 0026: Interactive sessions expose first-class daemon-backed job management tools

Date: 2026-04-19
Status: Proposed

## Context

By the end of v0.2 M5, Allbert has a real daemon-owned scheduler, durable job definitions, runtime state, run history, failure surfacing, and a usable operator workflow through `allbert-cli jobs ...`. What it still lacks is a first-class prompt-facing path for job management.

That creates a product mismatch:

- the scheduler exists
- the daemon protocol already supports job lifecycle messages
- the user can manage jobs from the CLI
- but the interactive assistant cannot do the same thing through sanctioned tools

Without prompt-native job tools, a conversational request like "schedule a daily review" has no authoritative execution path. At best the assistant can suggest CLI commands or attempt brittle workarounds through generic tools.

## Decision

Interactive sessions should expose first-class daemon-backed job-management tools.

At minimum, the prompt-facing tool surface should support:

- `list_jobs`
- `get_job`
- `upsert_job`
- `pause_job`
- `resume_job`
- `run_job`
- `remove_job`
- recent run and failure inspection for existing jobs

These tools should call into `JobManagerService` through the existing daemon-owned pathway. They should not treat job management as direct file editing under `~/.allbert/jobs/definitions/`, and they should not depend on spawning `allbert-cli jobs ...` as a subprocess.

## Consequences

**Positive**
- Makes recurring jobs a real conversational capability rather than only an operator feature.
- Reuses the daemon-owned persistence and validation path instead of creating a second authority.
- Keeps run history, failure surfacing, and state mutation consistent no matter how the user initiated the change.

**Negative**
- Adds more prompt-facing tool surface that must be documented and tested carefully.
- Requires explicit policy for durable schedule mutation, which is deferred to a separate ADR.

**Neutral**
- `allbert-cli jobs ...` remains the canonical operator escape hatch.
- Future frontends can reuse the same daemon-backed job tool semantics.

## References

- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
- [ADR 0013](0013-clients-attach-to-a-daemon-hosted-kernel-via-channels.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
