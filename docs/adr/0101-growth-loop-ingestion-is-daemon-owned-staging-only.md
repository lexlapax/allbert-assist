# ADR 0101: Growth-loop ingestion is daemon-owned, single-endpoint, staging-only (parked stub)

Date: 2026-04-26
Status: Parked stub (future release; extracted from v0.15 on 2026-04-27)

## Context

The origin note's first concrete functional requirement is that Allbert grows with the user by ingesting daily activity:

> "when I search things in Google, I should be able to search things in my chat, the face and it records things that I search and extracts and remembers it and stores it for training the engines are the personality so that tune itself to me"

Through v0.14, the only ingestion path is the agent's own in-turn `web_search` and `fetch_url` with an opt-in `record_as` parameter ([ADR 0053](0053-background-web-learning-requires-explicit-user-intent.md)). That is a different feature: it captures what *the agent* searched mid-turn, not what *the user* did during their day.

The v0.15 plan now narrows to RAG, recall, help, and session indexing first ([ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)). Ambient ingestion remains important, but it is parked in [future plans](../plans/future-plans.md) so the retrieval substrate can land before new staged records start arriving. This ADR records the provisional ingestion posture until ingestion returns to active release planning.

## Decision (provisional)

Growth-loop ingestion should return with the following invariants:

1. **Single ingestion shape.** One daemon-owned `IngestRecord` client message. No per-source RPC. Adapters (CLI piped feed, browser extension, browser proxy mode, future Slack/iMessage/email readers) all normalize into the same shape.
2. **Daemon-owned trust.** The endpoint reuses the existing daemon IPC trust model ([ADR 0023](0023-local-ipc-trust-is-filesystem-scoped-no-token-auth-in-v0-2.md)). Browser-facing ingestion listeners, including extension POST and proxy/PAC mode, bind to loopback only and are disabled by default.
3. **Staging-only.** Every ingested record lands in `~/.allbert/memory/staging/<source>/<id>.md` with `kind: ingestion` and never auto-promotes to durable memory. Promotion stays the existing memory-curator review path.
4. **Opt-in per source.** Every ingest source is disabled by default on a fresh profile and is visible in `/settings show ingestion`. Adding an ingest source requires explicit operator action.
5. **Defensive double-redaction.** The v0.12.2 secret redactor runs at ingest time (first pass, defensive) and again at adapter-corpus build time (existing second pass, [ADR 0082](0082-trace-capture-privacy-and-redaction-posture.md)).
6. **Bounded by daily caps.** Per-record byte cap and per-day record cap enforced at the daemon. Existing daily monetary cost cap ([ADR 0051](0051-daily-cost-cap-is-a-hard-gate-at-turn-boundary.md)) covers any LLM use during ingestion review.
7. **No flag-day removals.** The existing `record_as` agent-driven path stays. The new ingestion path is additive.
8. **RAG after review.** Staged ingestion records may be searched through explicit review surfaces, but they do not become trusted prompt context. Promoted ingestion records enter RAG through the same durable-memory path as any other promoted memory.

Browser proxy mode is provisional but important enough to preserve for a future
ingestion design. The daemon may expose an optional local HTTP proxy and PAC file so
an operator can point a browser profile at Allbert without installing an
extension. The proxy must be honest about what it can see:

- plaintext HTTP can produce redacted full-URL records;
- HTTPS `CONNECT` tunnels produce host/port/timestamp records only;
- the first ingestion release does not install a local CA, intercept TLS,
  inspect bodies, cache responses, or claim exact search-query capture through
  the proxy path;
- `CONNECT` targets are restricted to web-safe ports by default.

The browser extension remains the exact page/search-query capture path. The
proxy is complementary: lower-friction host/URL metadata ingestion and a useful
operator-controlled routing option.

This ADR should be finalized only when ingestion moves from parked future plan
back to an active release plan.

## Consequences (preview)

- The "grows with you" promise becomes structurally real; v0.13 adapter training has a path from user activity → corpus.
- Ingestion adapters (browser extension, browser proxy mode, future Slack/iMessage/email) normalize through the daemon-owned ingestion shape.
- Staging-only avoids the trust trap of silently building a full activity log; reviewers see what landed before it shapes anything.
- The v0.15 RAG foundation gives future promoted ingest records a retrieval path without letting unreviewed staged ingest leak into ordinary turns.
- The daemon remains the single trust boundary, but a future ingestion release must document the loopback browser listener surface clearly because browsers can be configured to route traffic through it.

## Alternatives considered (preview)

- **Per-source RPC.** Rejected because every new source would be a protocol change.
- **Auto-promote ingested records to durable memory.** Rejected because it removes the review gate the rest of the memory system relies on.
- **Bundle the browser extension with the kernel build.** Rejected because the extension toolchain is foreign to Rust; a sibling repo keeps the kernel build clean.
- **Use only a browser extension.** Rejected as the full browser story because a proxy/PAC path lets an operator point a browser profile at Allbert without extension APIs or per-browser packaging. The proxy is weaker for HTTPS detail, so it complements rather than replaces the extension.
- **TLS-intercepting proxy with a local root CA.** Rejected for the first ingestion release because it is too privacy- and security-sensitive and would require separate ADR, operator education, and rollback tooling.
- **Skip a dedicated staged-memory kind and reuse `kind: research`.** Tentatively rejected because reviewers want to filter ingest separately from agent-staged candidates. Final decision lands when ingestion returns to active planning.
- **Build ingestion before RAG.** Rejected for sequencing because ingestion would create a larger review and memory corpus before Allbert has a unified retrieval substrate for help, memory, and future promoted ingest records.

## References

- [MDN: Proxy Auto-Configuration file](https://developer.mozilla.org/en-US/docs/Web/HTTP/Guides/Proxy_servers_and_tunneling/Proxy_Auto-Configuration_PAC_file)
- [RFC 9110 section 9.3.6: CONNECT](https://datatracker.ietf.org/doc/html/rfc9110#section-9.3.6)
- [docs/plans/future-plans.md](../plans/future-plans.md)
- [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
