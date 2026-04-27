# ADR 0078: Semantic memory is optional derived retrieval

Date: 2026-04-24
Status: Accepted

> **Amended in part by [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md) and [ADR 0107](0107-rag-vectors-use-local-ollama-embeddings-and-sqlite-vec.md) in v0.15 (planned)**: the v0.11 fake-provider semantic-memory seam becomes the precursor to a broader SQLite-backed RAG service. v0.15 plans real local Ollama embeddings through an owned seam while preserving provider-free lexical fallback and review gates.

## Context

ADR 0046 chose Tantivy/BM25 for v0.5 because it matched Allbert's markdown-first memory architecture and provider-free default validation. Embedding-based retrieval remains attractive for fuzzy recall, but making it default would add provider requirements, privacy questions, index complexity, and cost to normal operation.

v0.11 can prepare for semantic recall without changing the default retrieval contract.

## Decision

Semantic retrieval is optional and derived.

```toml
[memory.semantic]
enabled = false
provider = "none"
embedding_model = ""
hybrid_weight = 0.35
```

Rules:

- BM25/Tantivy remains the default retriever.
- When semantic retrieval is disabled, no embedding calls are made.
- When enabled, embeddings are stored in a derived index under `memory/index/semantic/`.
- The semantic index can be deleted and rebuilt from markdown ground truth.
- Hybrid ranking deterministically fuses BM25 and semantic scores.
- v0.11 ships a fake deterministic embedding provider for provider-free tests and validation. Real embedding providers are additive follow-up work that must preserve the off-by-default, derived-index contract.

## Consequences

**Positive**

- Allbert gains a path toward fuzzy recall without forcing hosted providers or vector dependencies on every user.
- Default memory search remains fast, local, and provider-free.
- Semantic retrieval can be evaluated experimentally without replacing Tantivy.

**Negative**

- Hybrid ranking adds tuning complexity when enabled.
- Operators need clear documentation about embedding provider privacy and cost.

**Neutral**

- v0.15 plans real local-vector RAG through ADR 0106 and ADR 0107, but vector retrieval remains optional and derived; no embedding call is required for lexical RAG fallback.

## References

- [docs/plans/v0.11-tui-and-memory.md](../plans/v0.11-tui-and-memory.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0046](0046-v0-5-memory-retrieval-uses-tantivy.md)
- [ADR 0066](0066-owned-provider-seam-over-rig-for-v0-10.md)
- [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
- [ADR 0107](0107-rag-vectors-use-local-ollama-embeddings-and-sqlite-vec.md)
