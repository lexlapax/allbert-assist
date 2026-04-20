# ADR 0045: Memory index is a derived artifact rebuilt from markdown ground truth

Date: 2026-04-20
Status: Proposed

## Context

Curated memory needs an index to make ranked retrieval affordable. But the project already has a strong cross-cutting rule: markdown is the portable source of truth, and indexes or caches are rebuildable artifacts.

If the index becomes authoritative, memory portability and inspectability suffer.

## Decision

The v0.5 memory index is a derived artifact only.

- Approved memory markdown remains the source of truth.
- The retriever index is rebuilt from the markdown corpus whenever it is missing, stale, or schema-incompatible.
- Staged entries are indexed according to their own review semantics, not merged into the approved durable index by accident.
- The index is local runtime state, not a portable artifact meant to be copied between systems as authoritative memory.

## Consequences

**Positive**

- Durable memory stays inspectable and portable.
- Index corruption is recoverable.
- The retriever implementation can evolve without reauthoring the corpus.

**Negative**

- Cold-start or rebuild time becomes a real operational concern that v0.5 must handle cleanly.

**Neutral**

- Future retriever implementations may change the index format, but not the markdown-ground-truth rule.

## References

- [docs/plans/v0.5-curated-memory.md](../plans/v0.5-curated-memory.md)
- [docs/plans/roadmap.md](../plans/roadmap.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
