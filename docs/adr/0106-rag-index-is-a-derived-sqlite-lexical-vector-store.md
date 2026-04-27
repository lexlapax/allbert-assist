# ADR 0106: RAG index is a derived SQLite lexical/vector store

Date: 2026-04-26
Status: Draft (formalized when v0.15 plan is finalized)

Amends: ADR 0045, ADR 0046, ADR 0078

## Context

Allbert already has several retrieval surfaces:

- v0.5 memory search uses Tantivy/BM25 for curated memory.
- v0.11 adds an optional semantic-memory seam, but the shipped provider is a
  deterministic fake and the derived index is memory-local JSON.
- v0.14.3 plans a schema-bound router before full prompt assembly.
- v0.15 plans growth-loop ingestion, which will create more candidate context
  than Allbert can use responsibly without a broader retrieval substrate.

The missing piece is RAG across current operator docs, CLI help, settings,
memory, facts, episode history, skills metadata, and later promoted ingestion
records. That substrate must stay local-first, rebuildable, inspectable, and
bounded. It must not turn staged ingestion into trusted prompt context, and it
must not replace the router as the intent/action authority.

## Decision

v0.15 introduces a `RagService` backed by a derived SQLite database.

- Concrete behavior lives in `allbert-kernel-services`.
- Core owns only config and DTO/contract types frontends need.
- The derived index lives under `~/.allbert/index/rag/rag.sqlite`.
- Source markdown, generated command descriptors, settings descriptors, skill
  metadata, memory markdown, and promoted ingestion records remain the sources
  of truth.
- SQLite metadata tables track sources, chunks, content hashes, schema version,
  source kind, provenance, and lifecycle timestamps.
- SQLite FTS is the provider-free lexical retrieval baseline.
- Optional vector retrieval layers behind an owned vector backend trait.
- `sqlite-vec` is the first vector backend because it has a Rust crate and can
  be statically linked with the application.
- Official SQLite `vec1` is tracked as a future candidate, but not selected for
  the first implementation because it is new and its documentation still warns
  about testing maturity.
- `sqlite-vss` is rejected because its upstream project points active work to
  `sqlite-vec`.

The planned config shape is:

```toml
[rag]
enabled = true
vector_enabled = false
embedding_provider = "none"
embedding_model = ""
max_chunks_per_turn = 6
max_chunk_bytes = 1200
sources = ["operator_docs", "commands", "settings", "memory"]
```

Allowed embedding providers are `none`, `ollama`, `openai`, and `fake`.
`fake` is for deterministic tests. Ollama is the preferred real local path.
OpenAI is optional, cost-logged, and daily-cost-cap gated.

## Retrieval rules

- RAG provides bounded evidence, not action authority.
- v0.14.3's schema-bound router remains the authority for intent and guarded
  action drafts.
- A cheap pre-router RAG hint may query only command, help, and settings
  sources through lexical FTS.
- Vector embeddings do not run on every turn by default.
- `meta` and help-like turns may retrieve operator docs, command descriptors,
  settings descriptors, and runbook snippets.
- `memory_query` turns may retrieve durable memory, approved facts, and labelled
  episode working history.
- Ordinary task turns receive bounded RAG snippets only when the router posture
  or explicit user request justifies it.
- Staged memory and staged ingestion records are searchable for explicit review
  surfaces but are not trusted prompt context.
- Promoted ingestion records enter RAG through the durable-memory path.

## Consequences

**Positive**

- Help-like prompts can be answered from current operator docs instead of vague
  model memory.
- Growth-loop ingestion has a retrieval substrate before it starts collecting
  new staged records.
- Provider-free lexical RAG remains available without embeddings.
- Semantic retrieval grows from a memory-only seam into a cross-source service
  without removing the existing memory search contract.

**Negative**

- SQLite plus a vector extension adds a dependency surface that needs version
  pinning and dependency-gate review.
- The system now has both Tantivy memory search and SQLite RAG until a later
  release decides whether consolidation is worth the migration cost.
- Hosted embeddings add privacy and cost questions when enabled.

**Neutral**

- Tantivy/BM25 remains the v0.5 curated-memory baseline.
- The v0.11 semantic-memory JSON seam may become a compatibility layer or be
  retired once the v0.15 RAG service owns vector retrieval.
- Future releases may switch the vector backend if official SQLite `vec1`
  matures enough to justify replacing `sqlite-vec`.

## References

- [docs/plans/v0.15-growth-loop.md](../plans/v0.15-growth-loop.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0046](0046-v0-5-memory-retrieval-uses-tantivy.md)
- [ADR 0078](0078-semantic-memory-is-optional-derived-retrieval.md)
- [SQLite vec1](https://sqlite.org/vec1)
- [sqlite-vec Rust docs](https://alexgarcia.xyz/sqlite-vec/rust.html)
- [sqlite-vss](https://github.com/asg017/sqlite-vss)
- [Ollama embeddings](https://docs.ollama.com/capabilities/embeddings)
- [OpenAI embeddings](https://platform.openai.com/docs/guides/embeddings)
