# ADR 0108: RAG indexing is daemon-maintained and channel-visible

Date: 2026-04-27
Status: Accepted

Amends: ADR 0019, ADR 0022, ADR 0075
Related: ADR 0106, ADR 0107

## Context

RAG indexing is deterministic service work. It scans local sources, chunks text,
updates SQLite FTS, calls local embeddings when vector indexing is enabled, and
writes derived index rows. That is different from prompt-authored scheduled
jobs, which launch a model turn and rely on tool calls.

v0.15 also needs RAG status and search to be visible from the same operator
surfaces as the rest of Allbert: CLI, REPL/TUI, Telegram, settings, telemetry,
and daemon activity.

## Decision

v0.15 adds daemon-owned RAG maintenance rather than a bundled prompt job.

- `RagMaintenanceService` lives in the daemon/service layer and calls
  `RagService` directly.
- Maintenance uses central `[rag.index]` settings for schedule, stale-only
  behavior, startup rebuild, run limits, and chunk caps.
- It may reuse the bounded schedule DSL semantics, but it does not create or
  mutate markdown job definitions under `jobs/definitions`.
- It records run history in the RAG SQLite database.
- It emits daemon activity updates while indexing.
- It respects a single rebuild lock shared by manual and scheduled rebuilds.

RAG settings are first-class settings catalog entries. Operators can inspect and
change them through existing settings surfaces:

- `/settings show rag`
- `/settings show rag.vector`
- `/settings show rag.index`
- `allbert-cli settings ...`

v0.15 introduces protocol v7 for channel-visible RAG status and search:

- status request/response;
- search request/response with bounded snippets and source labels;
- rebuild start/completion/error notifications for clients that support them;
- per-peer filtering so v2-v6 clients never receive v7-only messages.

## Channel rules

- CLI is authoritative for status, doctor, rebuild, search, and GC.
- REPL/TUI support `/rag status`, `/rag search <query>`, and `/rag rebuild
  --stale-only`.
- Telegram supports `/rag status` and `/rag search <query>` only in v0.15.
- Long-running rebuilds are not started from Telegram in v0.15.
- Prompt-time help/meta/memory-query retrieval benefits every channel because
  the daemon prompt path owns RAG injection.
- TUI status-line may show an optional `rag` item with `ok`, `stale`,
  `lexical`, or `degraded` posture.

## Consequences

**Positive**

- Indexing does not depend on an LLM turn or tool-call reliability.
- Operators can understand RAG health without reading SQLite files.
- Channels get consistent status/search behavior through the daemon.
- Scheduled vector maintenance can run during quiet hours or operator-chosen
  windows.

**Negative**

- The daemon gains another supervised maintenance service.
- Protocol v7 adds compatibility tests and filtering work.
- Settings catalog and setup need a new group and more descriptors.

**Neutral**

- Existing prompt-authored jobs remain unchanged.
- `memory-compile` and other maintenance jobs stay disabled-by-default prompt
  jobs; RAG indexing is a deterministic service task instead.

## Alternatives considered

- **Bundle `rag-index-refresh` as a normal scheduled job.** Rejected because it
  would require a model to call the right tool for deterministic indexing.
- **Only expose RAG through CLI.** Rejected because Allbert's daemon/channel
  posture requires operator state to be visible across surfaces.
- **Rebuild synchronously during every turn.** Rejected because vector indexing
  can be expensive and would make ordinary turns unpredictable.
- **No scheduled maintenance.** Rejected because stale vectors would become a
  normal failure mode after memory/session changes.

## References

- [docs/plans/v0.15-rag-recall-help.md](../plans/v0.15-rag-recall-help.md)
- [ADR 0019](0019-v0-2-services-are-supervised-in-process-tasks-with-future-subprocess-seams.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0075](0075-session-telemetry-is-kernel-owned-protocol-state.md)
- [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
- [ADR 0107](0107-rag-vectors-use-local-ollama-embeddings-and-sqlite-vec.md)
