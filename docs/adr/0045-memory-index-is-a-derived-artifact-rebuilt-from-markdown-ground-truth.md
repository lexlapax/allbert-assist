# ADR 0045: Memory index is a derived artifact rebuilt from markdown ground truth

Date: 2026-04-20
Status: Accepted

## Context

Curated memory needs an index to make ranked retrieval affordable. But the project already has a strong cross-cutting rule: markdown is the portable source of truth, and indexes or caches are rebuildable artifacts.

If the index becomes authoritative, memory portability and inspectability suffer.

## Decision

The v0.5 memory index is a derived artifact only.

- Approved memory markdown remains the source of truth.
- `memory/manifest.json` is a kernel-maintained enumeration of approved durable documents; it is authored by the kernel during promotion and compaction and can be rebuilt from scanning `notes/` and `daily/` at any time.
- The retriever index is rebuilt from the markdown corpus (enumerated via the manifest) whenever it is missing, stale, or schema-incompatible. A `memory/index/meta.json` file records schema version, last rebuild time, and doc counts.
- Staging entries live in the same single retriever index as durable entries, distinguished by a per-document `tier` field. Prefetch always applies `tier = "durable"`; staging content never auto-injects into the root prompt (ADR 0041). The single-index shape is chosen for operational simplicity — one rebuild path, one schema version — not because the two tiers are interchangeable.
- The index is local runtime state, not a portable artifact meant to be copied between systems as authoritative memory.
- Index rebuild runs under an advisory file lock (`memory/index/.rebuild.lock`) so concurrent rebuild attempts serialize rather than race.

## Consequences

**Positive**

- Durable memory stays inspectable and portable.
- Index corruption is recoverable; a `rm -rf memory/index && allbert-cli memory rebuild-index` always restores ranked retrieval.
- The retriever implementation can evolve without reauthoring the corpus.
- One index to rebuild and monitor, not two.

**Negative**

- Cold-start or rebuild time becomes a real operational concern that v0.5 must handle cleanly; v0.5 commits to explicit perf budgets (see plan).
- Sharing one index across tiers makes the "never auto-inject staging" rule a software invariant rather than a physical one; tests must assert it.

**Neutral**

- Future retriever implementations may change the index format, but not the markdown-ground-truth rule.
- The specific library commitment lives in ADR 0046, not here.

## References

- [docs/plans/v0.05-curated-memory.md](../plans/v0.05-curated-memory.md)
- [docs/plans/roadmap.md](../plans/roadmap.md)
- [ADR 0038](0038-natural-interface-is-the-users-extension-surface.md)
- [ADR 0041](0041-memory-retrieval-uses-bounded-prefetch-and-explicit-search-read.md)
- [ADR 0046](0046-v0-5-memory-retrieval-uses-tantivy.md)
