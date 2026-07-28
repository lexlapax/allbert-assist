# ADR 0002: Markdown-First Memory

## Status

Accepted.

## Context

Allbert should become more personal over time while keeping the user in control
of what it remembers. The origin note calls for memory that can be stored in
markdown files for posterity and transfer, with compiled runtime views for
performance. The vision keeps the same posture: user-owned knowledge should
remain readable, portable, and inspectable.

Storing memory only in an opaque database or vector index would make early
development faster in some ways, but it would weaken the core product promise:
the assistant should grow with the user without making its memory hard to
understand or move.

## Decision

Markdown files are the source of truth for Allbert memory. v0.01 will store
notes, preferences, traces, skill records, and recent memory entries as
human-readable markdown. Runtime indexes, embeddings, summaries, and other
compiled views may be added later, but they are derived artifacts rather than
the primary memory record.

## Consequences

- Users and developers can inspect and edit early memory without special tools.
- Memory can be transferred to another system by moving files.
- Early retrieval should stay simple: recent entries, selected files, and
  summaries before embeddings or vector search.
- Future indexing work must preserve markdown as the durable source of truth.

## Amendment (v1.3 readiness, 2026-07-28) — authorities and projections

The markdown-first rule applies specifically to **Memory**. Long-term-memory
claim streams remain human-readable markdown and are the canonical Memory
record. Their compiled candidate/index projection is disposable and rebuildable;
it cannot create, revise, retire, or forget a claim.

For a v1.3 claim stream, the only supported manual change shape is a new
append-only revision. A raw filesystem append is quarantined until the operator
reviews and confirms that exact revision through the registered one-claim
repair/import action. Confirmation appends a content-free
`manual_import_confirmed` transition that references the unchanged pending
revision digest and carries a domain-separated integrity tag through existing
Key Custody. Projection rebuild recognizes the manual revision only when that
valid transition immediately follows it; no Repo ledger becomes a second
authority. File contents alone never grant authority.
Modifying, removing, or reordering an earlier revision breaks the digest chain
and remains quarantined. Allbert surfaces explicit repair/import guidance and
never silently rewrites the file. Legacy flat entries retain their existing
meaning and upgrade lazily on their next accepted change; there is no bulk
rewrite.

Conversation history has a different authority:
`AllbertAssist.Conversations.Corpus` is the canonical, policy-filtered
conversation read boundary over the durable conversation store. It is not a
second Memory source of truth. Search Central's SQLite FTS database and Memory's
compiled projection are separate derived stores, each rebuildable only from its
own canonical authority. Search results never become Memory merely because they
were found or summarized; ADR 0089 owns Memory collection and review, while ADR
0092 owns search.
