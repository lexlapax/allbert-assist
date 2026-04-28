# ADR 0108: RAG indexing is daemon-maintained and channel-visible

Date: 2026-04-27
Status: Accepted

Amends: ADR 0019, ADR 0022, ADR 0075
Related: ADR 0106, ADR 0107, ADR 0110

## Context

RAG indexing is deterministic service work. It scans local sources, chunks text,
updates SQLite FTS, calls local embeddings when vector indexing is enabled, and
writes derived index rows. That is different from prompt-authored scheduled
jobs, which launch a model turn and rely on tool calls.

v0.15 also needs RAG status and search to be visible from the same operator
surfaces as the rest of Allbert: CLI, REPL/TUI, Telegram, settings, telemetry,
and daemon activity.

ADR 0110 adds logical RAG collections before v0.15 closeout. Maintenance must
therefore distinguish default system collections from explicit user collections
without turning user corpora into prompt-authored jobs. URL-backed user
collections also need daemon-owned refresh semantics so network fetch,
conditional refresh, and safety failures are visible as service posture rather
than hidden model behavior.

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
- It owns both system and user collection rebuilds, but automatic startup and
  scheduled maintenance default to system collections only.
- User collection rebuilds run on explicit local operator/RAG-skill request in
  v0.15 M7.
- URL-backed user collection fetch/rebuild runs through the same maintenance
  lock and records skipped/degraded runs for robots, URL-safety, network,
  content-type, timeout, and byte-cap failures.

RAG settings are first-class settings catalog entries. Operators can inspect and
change them through existing settings surfaces:

- `/settings show rag`
- `/settings show rag.vector`
- `/settings show rag.index`
- `allbert-cli settings ...`

v0.15 introduces protocol v7 for channel-visible RAG maintenance and search:

- `RagStatus` request/response;
- `RagSearch` request/response with bounded snippets and source labels;
- collection-aware search/rebuild filters for `collection_type` and named
  collections;
- `RagRebuildStart`, `RagRebuildCancel`, progress, finished, cancelled, and
  error messages for clients that support them;
- `RagGc` request/result for local operator cleanup;
- per-peer filtering so v2-v6 clients never receive v7-only messages.

## Channel rules

- CLI is authoritative for status, doctor, rebuild, search, and GC.
- CLI is authoritative for user collection list/show/create, ingest/rebuild,
  search, and delete operations, including explicit URL sources.
- Local natural-language sessions can invoke the first-party `rag` skill for
  user collection list/show, create, ingest/rebuild, search, attach/detach, and
  delete. The skill calls kernel-services tools and does not own maintenance or
  trust policy.
- REPL/TUI support `/rag status`, `/rag search <query>`, `/rag rebuild
  [--stale-only] [--vectors]`, and `/rag gc [--dry-run]`.
- Telegram supports `/rag status` and `/rag search <query>` only in v0.15.
- Long-running rebuilds are not started from Telegram in v0.15.
- Telegram must not create, ingest, rebuild, delete, or attach user
  collections in v0.15 M7, and it must not initiate URL fetches.
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
- User collection indexing is visible and controllable without creating hidden
  prompt jobs, silently scanning local folders, or silently fetching URLs.

**Negative**

- The daemon gains another supervised maintenance service.
- Protocol v7 adds compatibility tests and filtering work.
- Settings catalog and setup need a new group and more descriptors.
- Collection-aware search/rebuild and user collection lifecycle commands add
  operator-surface and model-tool test coverage. Dedicated protocol lifecycle
  mutation messages are deferred.

**Neutral**

- Existing prompt-authored jobs remain unchanged.
- `memory-compile` and other maintenance jobs stay disabled-by-default prompt
  jobs; RAG indexing is a deterministic service task instead.
- Scheduled RAG maintenance remains system-collection-first until a later
  release explicitly opts user collections into automatic refresh.

## Alternatives considered

- **Bundle `rag-index-refresh` as a normal scheduled job.** Rejected because it
  would require a model to call the right tool for deterministic indexing.
- **Only expose RAG through CLI.** Rejected because Allbert's daemon/channel
  posture requires operator state to be visible across surfaces.
- **Rebuild synchronously during every turn.** Rejected because vector indexing
  can be expensive and would make ordinary turns unpredictable.
- **No scheduled maintenance.** Rejected because stale vectors would become a
  normal failure mode after memory/session changes.
- **Use prompt-authored jobs for user collection refresh.** Rejected for the
  same reason as system RAG maintenance: deterministic indexing should not
  depend on a model turn or tool-call reliability.

## References

- [docs/plans/v0.15-rag-recall-help.md](../plans/v0.15-rag-recall-help.md)
- [ADR 0019](0019-v0-2-services-are-supervised-in-process-tasks-with-future-subprocess-seams.md)
- [ADR 0022](0022-job-definitions-are-markdown-with-frontmatter-and-a-bounded-schedule-dsl.md)
- [ADR 0075](0075-session-telemetry-is-kernel-owned-protocol-state.md)
- [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
- [ADR 0107](0107-rag-vectors-use-local-ollama-embeddings-and-sqlite-vec.md)
- [ADR 0110](0110-rag-collections-separate-system-and-user-corpora.md)
