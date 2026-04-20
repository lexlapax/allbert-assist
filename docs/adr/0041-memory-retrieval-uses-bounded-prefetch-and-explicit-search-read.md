# ADR 0041: Memory retrieval uses bounded prefetch and explicit search/read

Date: 2026-04-20
Status: Accepted

## Context

Once durable memory grows beyond a few always-injected snippets, the runtime needs a retrieval strategy. The two bad extremes are:

- inject too much memory on every turn, making prompts bloated and unpredictable;
- inject nothing and require the model to guess when memory matters.

Allbert already uses progressive disclosure for skills. Memory needs a similar rule.

## Decision

v0.5 uses a two-part retrieval model:

1. **Bounded prefetch**
   - before the first root-agent model round, the kernel may run one bounded retrieval pass based on intent and turn cues;
   - prefetch queries **the approved durable tier only** — staging is never auto-injected, even when a staged entry would score high;
   - prefetch returns tier-1 retrieval results: titles, paths, snippets, scores, provenance.
2. **Explicit search/read**
   - agents and skills can explicitly call `search_memory(query, tier, limit)` for further ranked recall;
   - when `tier = "staging"`, the retriever applies a tier filter that restricts results to staged entries; this is how the curator skill and operator CLI browse the review queue;
   - explicit full-body reads continue to use `read_memory`.

The kernel may permit one bounded refresh retrieval pass after material external evidence arrives from tools or sub-agents. It does not permit unbounded repeated retrieval loops inside a turn.

Progressive disclosure applies:

- tier 1: document metadata and snippets
- tier 2: full bodies via explicit read

### Index shape

v0.5 uses a single retrieval index with a `tier` field per document (`durable` or `staging`). This is simpler to operate and rebuild than two parallel indexes, and the tier filter gives the same auto-injection guarantee as physical separation: prefetch always applies `tier = "durable"`, so staged entries are physically in the same index but never returned to prefetch callers. The library commitment (tantivy) is codified in ADR 0046.

## Consequences

**Positive**

- The first root-agent call gets relevant memory without loading the whole corpus.
- Retrieval remains legible and bounded.
- The existing `read_memory` tool keeps its role as the full-document seam.
- One index, one rebuild path, one schema version.

**Negative**

- The kernel needs a policy for when prefetch should fire.
- Some relevant memory may be missed on the first pass and require explicit search.
- A bug that fails to apply the tier filter on prefetch would leak staging into the root prompt; tests must assert this invariant.

**Neutral**

- BM25 is the default v0.5 retriever (via tantivy), but the explicit search/read contract could outlive that specific implementation.

## References

- [docs/plans/v0.5-curated-memory.md](../plans/v0.5-curated-memory.md)
- [ADR 0036](0036-progressive-disclosure-maps-to-prompt-construction-stages.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
