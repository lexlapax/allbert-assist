# ADR 0101: Growth-loop ingestion is daemon-owned, single-endpoint, staging-only (stub)

Date: 2026-04-26
Status: Draft (formalized when v0.15 plan is finalized)

## Context

The origin note's first concrete functional requirement is that Allbert grows with the user by ingesting daily activity:

> "when I search things in Google, I should be able to search things in my chat, the face and it records things that I search and extracts and remembers it and stores it for training the engines are the personality so that tune itself to me"

Through v0.14, the only ingestion path is the agent's own in-turn `web_search` and `fetch_url` with an opt-in `record_as` parameter ([ADR 0053](0053-background-web-learning-requires-explicit-user-intent.md)). That is a different feature: it captures what *the agent* searched mid-turn, not what *the user* did during their day.

The v0.15 stub now names ambient ingestion as the next major release after the v0.14.1 repair pass and v0.14.2 structural split. This ADR records the provisional posture until the full v0.15 plan is drafted.

## Decision (provisional)

Growth-loop ingestion lands in v0.15 with the following invariants:

1. **Single endpoint.** One daemon-owned `IngestRecord` client message. No per-source RPC. Adapters (CLI piped feed, browser extension, future Slack/iMessage/email readers) all post the same shape.
2. **Daemon-owned trust.** The endpoint reuses the existing daemon IPC trust model ([ADR 0023](0023-local-ipc-trust-is-filesystem-scoped-no-token-auth-in-v0-2.md)). Localhost only. No network listener beyond what the daemon already exposes.
3. **Staging-only.** Every ingested record lands in `~/.allbert/memory/staging/<source>/<id>.md` with `kind: ingestion` and never auto-promotes to durable memory. Promotion stays the existing memory-curator review path.
4. **Opt-in per source.** Every ingest source is disabled by default on a fresh profile and is visible in `/settings show ingestion`. Adding an ingest source requires explicit operator action.
5. **Defensive double-redaction.** The v0.12.2 secret redactor runs at ingest time (first pass, defensive) and again at adapter-corpus build time (existing second pass, [ADR 0082](0082-trace-capture-privacy-and-redaction-posture.md)).
6. **Bounded by daily caps.** Per-record byte cap and per-day record cap enforced at the daemon. Existing daily monetary cost cap ([ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)) covers any LLM use during ingestion review.
7. **No flag-day removals.** The existing `record_as` agent-driven path stays. The new ingestion path is additive.

This ADR will be finalized when the v0.15 plan moves from Stub to Draft.

## Consequences (preview)

- The "grows with you" promise becomes structurally real; v0.13 adapter training has a path from user activity → corpus.
- Ingestion adapters (browser extension, future Slack/iMessage/email) live outside the kernel crates, posting through the existing daemon IPC.
- Staging-only avoids the trust trap of silently building a full activity log; reviewers see what landed before it shapes anything.
- The daemon IPC remains the single trust boundary; there is no new auth surface.

## Alternatives considered (preview)

- **Per-source RPC.** Rejected because every new source would be a protocol change.
- **Auto-promote ingested records to durable memory.** Rejected because it removes the review gate the rest of the memory system relies on.
- **Bundle the browser extension with the kernel build.** Rejected because the extension toolchain is foreign to Rust; a sibling repo keeps the kernel build clean.
- **Skip a dedicated staged-memory kind and reuse `kind: research`.** Tentatively rejected because reviewers want to filter ingest separately from agent-staged candidates. Final decision lands when v0.15 plan is finalized.
