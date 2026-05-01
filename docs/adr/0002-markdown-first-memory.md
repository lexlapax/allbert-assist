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

