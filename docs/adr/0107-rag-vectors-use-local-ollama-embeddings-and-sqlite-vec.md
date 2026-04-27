# ADR 0107: RAG vectors use local Ollama embeddings and sqlite-vec

Date: 2026-04-27
Status: Draft (formalized when v0.15 RAG plan is finalized)

Amends: ADR 0078, ADR 0106

## Context

v0.11 added a fake-provider semantic memory seam, but it is memory-local,
JSON-backed, and not a real operator retrieval path. v0.15 is now explicitly a
real local-vector RAG release. The vector path needs to work on a normal local
Allbert machine without introducing a hosted dependency or an external vector
database server.

Allbert already defaults fresh profiles to local Ollama for chat. Ollama also
documents an embedding API at `/api/embed`, recommended embedding models, batch
input, cosine-similarity guidance, and L2-normalized vectors. For storage,
`sqlite-vec` has a Rust crate that embeds the C source and can be statically
linked, while official SQLite `vec1` is promising but very new and still calls
out testing and optimization gaps.

## Decision

v0.15 uses:

- Ollama as the first real embedding provider;
- `embeddinggemma` as the recommended local embedding model;
- `sqlite-vec` as the first vector backend;
- cosine distance for vector search;
- hybrid retrieval as the default healthy mode;
- fake embeddings only for deterministic tests and explicit development
  fixtures.

The `EmbeddingProvider` seam is owned by Allbert and separate from chat
completion. It supports batch embedding for indexing and single-query embedding
for retrieval. The Ollama provider calls the local `/api/embed` endpoint and
stores the embedding model, base URL, dimension, and vector-health state in RAG
metadata.

Hosted embedding providers are deferred from v0.15. They can reuse the owned
embedding-provider seam later, but need a separate privacy/cost decision and
daily-cost-cap integration.

## Operational rules

- Vector indexing is never performed silently inside every ordinary turn.
- Query embeddings run only for explicit RAG search, help/meta retrieval,
  memory-query retrieval, or router-approved retrieval.
- If Ollama is unavailable, the embedding model is missing, dimensions do not
  match, or a query embedding fails, RAG falls back to lexical search and marks
  vector posture degraded.
- Changing embedding provider or model invalidates all stored vectors and
  requires vector rebuild.
- `allbert-cli rag doctor` must report Ollama reachability, model availability,
  expected dimension, stored dimension, vector table health, and remediation.

## Consequences

**Positive**

- v0.15 delivers real local semantic retrieval instead of another fake-only
  seam.
- The default path matches Allbert's local-first provider posture.
- RAG does not require Qdrant, Chroma, pgvector, or another server.
- SQLite stays the single local derived index file.

**Negative**

- Operators need a local embedding model installed for vector behavior.
- `sqlite-vec` is pre-v1, so the dependency needs pinning and compactness-gate
  attention.
- Local vector rebuild can be CPU/GPU expensive enough to need scheduling,
  status, and cancellation behavior.

**Neutral**

- Provider-free lexical RAG remains available.
- Fake embeddings remain valid for deterministic CI.
- Official SQLite `vec1` remains a future migration candidate.

## Alternatives considered

- **Lexical-only FTS in v0.15.** Rejected because the release is now intended to
  prove real RAG recall, not only better help search.
- **Fake-only vectors.** Rejected because v0.11 already proved a fake semantic
  seam; v0.15 needs real local vectors.
- **OpenAI embeddings in v0.15.** Deferred. Hosted embeddings are useful but
  introduce upload, privacy, and cost concerns that should not block the local
  foundation.
- **`sqlite-vss`.** Rejected because upstream active work moved toward
  `sqlite-vec`.
- **SQLite `vec1`.** Deferred because it is new and still documents testing and
  optimization gaps.
- **External vector database.** Rejected for v0.15 because it adds another
  local service and weakens the single-file derived-index posture.

## References

- [docs/plans/v0.15-rag-recall-help.md](../plans/v0.15-rag-recall-help.md)
- [ADR 0106](0106-rag-index-is-a-derived-sqlite-lexical-vector-store.md)
- [Ollama embeddings](https://docs.ollama.com/capabilities/embeddings)
- [sqlite-vec Rust docs](https://alexgarcia.xyz/sqlite-vec/rust.html)
- [sqlite-vec KNN docs](https://alexgarcia.xyz/sqlite-vec/features/knn.html)
- [SQLite vec1](https://sqlite.org/vec1)

