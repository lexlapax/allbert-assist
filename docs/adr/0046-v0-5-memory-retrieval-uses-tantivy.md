# ADR 0046: v0.5 memory retrieval uses tantivy

Date: 2026-04-20
Status: Accepted

> **Amended in part by [ADR 0078](0078-semantic-memory-is-optional-derived-retrieval.md) in v0.11**: BM25/Tantivy remains the default retriever. Semantic retrieval may layer alongside it only as an off-by-default derived index.

## Context

v0.5 introduces curated memory (ADR 0040) with a two-part retrieval model: bounded prefetch plus explicit `search_memory` / `read_memory` (ADR 0041). The index is a derived artifact (ADR 0045). What v0.5 still has to commit to is the retrieval library.

Three broad options were considered:

1. **Hand-rolled BM25.** Roughly 300 lines over `pulldown-cmark` + `rust-stemmers` + a plain inverted index. Minimal dependency footprint. We would own tokenization, stemming, stop-word handling, score tuning, phrase support, field weighting, and persistence forever.

2. **A small BM25-only crate** (e.g. `rust-bm25`). Smaller than tantivy; fewer dependencies; correspondingly fewer features (no phrase queries, no multi-field, no mmap persistence).

3. **tantivy.** Full Lucene-style search library. BM25 by default with tuned `k1` / `b`. Ships unicode tokenizer, stemming, stop-word lists, phrase queries, multi-field documents, persistent mmap'd on-disk index, incremental commits, field-level filters, and a stable Rust API. Transitive dependency count is meaningful (~15 direct transitives in the retrieval subtree).

The retrieval surface v0.5 needs is not going to shrink:

- tier filter on every query (ADR 0041 commits the single-index-with-tier shape)
- title / body / tags / date fields
- phrase support for named entities in `MEMORY.md`
- snippet extraction with score-aware highlighting
- mmap persistence so cold-start is cheap and `rebuild-index` is legible
- room to add recency boost in M3+ without rewriting retrieval

Option 1 reinvents all of that. Option 2 punts half of it. Option 3 absorbs the growth without rework.

## Decision

v0.5 uses [`tantivy`](https://github.com/quickwit-oss/tantivy) as the memory retrieval engine.

- The on-disk index lives at `~/.allbert/memory/index/tantivy/` and is owned by tantivy's segment format.
- `memory/index/meta.json` records the kernel's retriever schema version, the tantivy version used to build the segments, last rebuild time, and doc counts. Schema-version drift triggers a rebuild.
- Indexed fields: `id` (stored+indexed), `path` (stored), `title` (text, stored), `body` (text), `tags` (facet or text, stored), `tier` (string, stored, filterable), `date` (date, stored, filterable).
- Tokenizer: default English analyzer plus the `en_stem` stemmer. Tokenizer choice is recorded in `meta.json` so an analyzer change forces a rebuild.
- Queries go through `tantivy::query::QueryParser` with tier filters applied as a `BooleanQuery` must-clause; prefetch hardcodes `tier = "durable"`.
- The retriever is owned by a single long-lived writer in the kernel; CLI-driven commands talk to the kernel via existing IPC (ADR 0023), never opening a second writer against the index directory.
- Rebuild and bulk writes take an advisory file lock (`memory/index/.rebuild.lock` via `fs2`); incremental writes commit as small segments and let tantivy merge.

Supporting crate commitments (all added in M1):

- `pulldown-cmark` — markdown → plain text for the indexed body.
- `serde_yaml` — staged-entry frontmatter (ADR 0047) and manifest fields.
- `fs2` — advisory file locks on the index directory.
- `tempfile` — temp-then-rename atomic writes for `manifest.json`, staged entries, promoted entries.

### Why document this choice in code

The dependency footprint is non-trivial for a local-first binary. To prevent quiet creep (or quiet removal), M1 lands:

- a top-of-file comment in the retriever module explaining why tantivy was picked and when to revisit,
- a `docs/adr/0046-*.md` reference in that comment,
- an audit note in `CARGO_DEPS.md` (or equivalent) listing tantivy's direct transitives with a short justification each.

## Consequences

**Positive**

- BM25, tokenization, stemming, stop words, phrase queries, and mmap persistence come for free and stay maintained upstream.
- Adding recency boost, field weighting, or facet filtering in later milestones is additive work, not a rewrite.
- Cold-start is cheap because tantivy segments are mmap'd.
- The single-writer / per-process index rule is straightforward to enforce and cheap to reason about.

**Negative**

- The binary grows noticeably from tantivy and its transitives. v0.5 commits an audit note and accepts the tradeoff.
- Tokenizer / analyzer changes force a rebuild; M1 records analyzer choice in `meta.json` specifically so we do not accidentally mismatch.
- One more upstream dependency to track for security advisories; `cargo audit` in CI must run against the tantivy subtree.

**Neutral**

- If a later release decides to replace tantivy (e.g. with a WASM-friendly retriever), the `search_memory` / `read_memory` contract from ADR 0041 survives the swap.
- Future optional embedding retrieval (explicitly deferred from v0.5) would likely layer alongside tantivy rather than replacing it.

## References

- [docs/plans/v0.05-curated-memory.md](../plans/v0.05-curated-memory.md)
- [ADR 0040](0040-curated-memory-has-identity-durable-staging-and-ephemeral-tiers.md)
- [ADR 0041](0041-memory-retrieval-uses-bounded-prefetch-and-explicit-search-read.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [tantivy](https://github.com/quickwit-oss/tantivy)
