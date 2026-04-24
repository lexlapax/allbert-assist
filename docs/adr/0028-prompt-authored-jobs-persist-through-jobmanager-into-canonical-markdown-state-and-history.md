# ADR 0028: Prompt-authored jobs persist through JobManagerService into canonical markdown, state, and history

Date: 2026-04-19
Status: Accepted

## Context

Once interactive sessions can author and mutate jobs, there is a choice about where those mutations go.

Possible approaches:

1. Let the assistant write files directly under `~/.allbert/jobs/definitions/`.
2. Let the assistant shell out to `allbert-cli jobs ...`.
3. Route prompt-authored mutations through the daemon-owned `JobManagerService`, which then persists canonical markdown definitions plus the associated mutable state and run metadata.

Approaches 1 and 2 create split authority or brittle escapes. v0.2 already has a real job manager and protocol surface, so the conversational path should reuse that same authority.

## Decision

Prompt-authored jobs persist through `JobManagerService` into the canonical persisted job model.

That means:

- the persisted job definition remains `~/.allbert/jobs/definitions/<name>.md`
- mutable runtime state remains `~/.allbert/jobs/state/<name>.json`
- run history remains append-only under `~/.allbert/jobs/runs/`
- failures remain append-only under `~/.allbert/jobs/failures/`

Interactive sessions may draft or preview a job definition in memory, but the committed mutation must go through the daemon-owned job manager so validation, state updates, and lifecycle semantics all stay consistent.

## Consequences

**Positive**
- Preserves one authoritative persistence path.
- Keeps CLI-initiated and prompt-initiated jobs behaviorally identical after persistence.
- Avoids relying on generic `write_file` or `process_exec` hacks for scheduler changes.

**Negative**
- Requires a translation layer from natural-language intent into normalized job payloads.
- Means prompt-native scheduling depends on the daemon job protocol, not just the local filesystem.

**Neutral**
- Users can still inspect and edit the markdown definitions directly if they want to operate at the file level.
- The persisted representation stays portable and inspectable even though the mutation path is daemon-backed.

## References

- [docs/plans/v0.02-scheduled-jobs.md](../plans/v0.02-scheduled-jobs.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0026](0026-interactive-sessions-expose-first-class-daemon-backed-job-management-tools.md)
- [ADR 0027](0027-durable-schedule-mutations-require-preview-and-explicit-confirmation.md)
