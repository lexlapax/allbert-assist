# ADR 0110: RAG collections separate system and user corpora

Date: 2026-04-27
Status: Accepted

Amends: ADR 0106, ADR 0108, ADR 0109
Related: ADR 0101

## Context

v0.15 M0-M6 implement a single derived SQLite RAG index over Allbert-owned
sources: operator docs, command and settings descriptors, skill metadata,
durable memory, approved facts, episode recall, session summaries, and
review-only staged memory. That is enough for system help, memory recall, and
prompt-time evidence.

The same substrate can also support user-requested task/corpus RAG: an operator
may want Allbert to ingest a local folder, a few files, or a bounded web URL
source for a specific task, search that content, and attach it to a session
without promoting it to durable memory. Without a collection boundary, user
corpora would be hard to separate from system help and memory, and prompt
eligibility would become ambiguous.

URL ingestion adds a separate trust problem. It is useful enough to include in
M7, but it cannot be ambient crawling or browser capture. It needs explicit
operator intent, HTTP(S)-only fetching, robots.txt handling, SSRF defenses,
redirect revalidation, content-type and byte caps, and conditional refresh
metadata.

## Decision

v0.15 M7 makes RAG collection-aware while keeping one derived SQLite database.

- The RAG database remains `~/.allbert/index/rag/rag.sqlite`.
- `rag_collections` is the parent catalog for sources and chunks.
- Every collection has `collection_type`: `system` or `user`.
- Every collection has a stable `collection_name`, `source_uri`, lifecycle
  timestamps, prompt/review/privacy posture, and stale/index/access posture.
- Existing v0.15 sources become default `system` collections.
- User collections are explicit, task-scoped, and never auto-injected into
  prompts by default.
- User collection ingestion in v0.15 M7 supports trusted local filesystem
  sources and explicit HTTP(S) URL sources.
- Local `file://` and `dir://` sources must stay under trusted roots.
- URL sources are exact-URL by default. Optional same-origin expansion requires
  an explicit operator cap such as crawl depth and page count.
- URL ingestion allows HTTPS by default and may allow explicit HTTP only with a
  visible degraded/insecure posture.
- URL ingestion must reject unsupported schemes, embedded credentials,
  localhost, loopback, link-local, private, multicast, broadcast, cloud metadata
  addresses, and any redirect target that fails the same checks.
- URL ingestion must use GET/HEAD only, a clear Allbert user agent,
  content-type allowlists, byte/page/time caps, robots.txt checks, and
  conditional refresh metadata such as ETag and Last-Modified.
- The built-in RAG skill is a thin operator/user interface over
  kernel-services collection APIs. It cannot own indexing policy, bypass
  filesystem or URL trust checks, weaken review-only gates, or grant prompt
  eligibility.

## Consequences

**Positive**

- System RAG and user task/corpus RAG share the same local vector and lexical
  engine without mixing trust boundaries.
- Operators can create and search temporary corpora without turning them into
  durable memory.
- Prompt-time retrieval remains conservative: system collections behave as
  M0-M6 already specify, and user collections require explicit selection.
- Local and URL ingestion have the same collection lifecycle, search filters,
  vector/lexical substrate, and prompt eligibility rules.

**Negative**

- The v0.15 closeout is reopened: schema v2, collection filtering, user
  ingestion, RAG skill surfaces, and additional tests become release-blocking.
- The service layer grows further and must remain under the ADR 0109 size gate.
- User-facing collection lifecycle commands and URL-fetch failure modes add more
  operator documentation and UX surface before tagging.

**Neutral**

- This does not introduce hosted embedding providers.
- This does not make ambient crawling, browser capture, authenticated web
  sessions, JavaScript execution, or growth-loop ingestion part of v0.15.
- This does not give user URL collections default prompt eligibility; they must
  still be explicitly selected or attached.
- This does not split RAG into multiple SQLite databases; collection isolation
  is logical and enforced by schema, filters, prompt policy, and tests.

## Alternatives considered

- **Separate SQLite database per collection.** Rejected for v0.15 because it
  complicates daemon maintenance, vector model invalidation, hybrid search, and
  status reporting before there is evidence that logical filtering is
  insufficient.
- **Treat user corpora as another source kind only.** Rejected because source
  kind alone does not capture ownership, prompt eligibility, source URI, access
  posture, or task scoping.
- **Use the RAG skill as the policy owner.** Rejected because skills are
  extension/interaction surfaces; kernel-services must own indexing, trust, and
  prompt-injection policy.
- **Defer web URLs.** Rejected because user task/corpus RAG is much less useful
  if it can only ingest local files. M7 includes URL ingestion, but only as
  explicit, bounded HTTP(S) collection sources with independent fetch and trust
  controls.
- **Use browser capture for URLs.** Rejected for M7 because browser state,
  authentication, JavaScript execution, cookies, and dynamic rendering create a
  larger privacy and replay surface than explicit HTTP(S) fetch.

## References

- [docs/plans/v0.15-rag-recall-help.md](../plans/v0.15-rag-recall-help.md)
- [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
- [ADR 0108](0108-rag-indexing-is-daemon-maintained-and-channel-visible.md)
- [ADR 0109](0109-v0-15-services-size-gate-rescoped-for-rag.md)
- [ADR 0101](0101-growth-loop-ingestion-is-daemon-owned-staging-only.md)
- [OWASP SSRF Prevention Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Server_Side_Request_Forgery_Prevention_Cheat_Sheet.html)
- [RFC 9309: Robots Exclusion Protocol](https://www.rfc-editor.org/rfc/rfc9309)
- [RFC 9110: HTTP Semantics](https://www.rfc-editor.org/rfc/rfc9110)
