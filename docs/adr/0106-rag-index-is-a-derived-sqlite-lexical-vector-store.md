# ADR 0106: RAG index is a derived SQLite vector and lexical store

Date: 2026-04-26
Status: Accepted

Amends: ADR 0045, ADR 0046, ADR 0078
Related: ADR 0107, ADR 0108

## Context

Allbert already has several retrieval surfaces:

- v0.5 memory search uses Tantivy/BM25 for curated memory.
- v0.11 adds an optional semantic-memory seam, but the shipped provider is a
  deterministic fake and the derived index is memory-local JSON.
- v0.14.3 ships a schema-bound router before full prompt assembly.
- future growth-loop ingestion will create more candidate context than Allbert
  can use responsibly without a broader retrieval substrate.

The missing piece is RAG across current operator docs, CLI help, settings,
memory, facts, episode history, session-derived history, skills metadata, and
future promoted ingestion records. That substrate must stay local-first,
rebuildable, inspectable, and bounded. It must not turn staged or future
ingestion records into trusted prompt context, and it must not replace the
router as the intent/action authority.

The v0.15 plan now treats real local vectors as release scope, not a follow-up.
SQLite FTS remains necessary for lexical fallback and source filtering, but the
primary v0.15 RAG path is hybrid retrieval over local vector search plus FTS.

## Decision

v0.15 introduces a `RagService` backed by a derived SQLite database.

- Concrete behavior lives in `allbert-kernel-services`.
- Core owns only config and DTO/contract types frontends need.
- The derived index lives under `~/.allbert/index/rag/rag.sqlite`.
- Source markdown, generated command descriptors, settings descriptors, skill
  metadata, memory markdown, session-derived recall artifacts, and future
  promoted ingestion records remain the sources of truth.
- SQLite metadata tables track sources, chunks, content hashes, schema version,
  source kind, provenance, lifecycle timestamps, vector posture, and run
  history.
- SQLite FTS is the lexical retrieval baseline and fallback.
- Vector retrieval is release scope and layers behind an owned vector backend
  trait.
- `sqlite-vec` is the first vector backend because it has a Rust crate, embeds
  the C source, and can be statically linked with the application.
- Official SQLite `vec1` is tracked as a future candidate, but not selected for
  the first implementation because it is new and its documentation still warns
  about testing maturity.
- `sqlite-vss` is rejected because its upstream project points active work to
  `sqlite-vec`.

The planned config shape is:

```toml
[rag]
enabled = true
mode = "hybrid"
max_chunks_per_turn = 6
max_chunk_bytes = 1200
max_prompt_bytes = 7200
sources = ["operator_docs", "commands", "settings", "skills_metadata", "memory", "facts", "episodes", "sessions"]

[rag.vector]
enabled = false
provider = "ollama"
model = "embeddinggemma"
base_url = "http://127.0.0.1:11434"
distance = "cosine"
batch_size = 16
query_timeout_s = 15
index_timeout_s = 900
fallback_to_lexical = true
fusion_vector_weight = 0.70

[rag.index]
auto_maintain = true
schedule_enabled = false
schedule = "@daily at 03:30"
stale_only = true
run_on_startup_if_missing = true
max_run_seconds = 1800
max_chunks_per_run = 5000
```

Allowed v0.15 embedding providers are `ollama` and `fake`. `fake` is for
deterministic tests only. Hosted embedding providers are deferred until a
separate privacy, cost, and provider-surface decision.

## Retrieval rules

- RAG provides bounded evidence, not action authority.
- v0.14.3's schema-bound router remains the authority for intent and guarded
  action drafts.
- A cheap pre-router RAG hint may query only command, help, and settings
  sources, returning source ids, titles, and short snippets only.
- Query embeddings do not run on every turn by default.
- `meta` and help-like turns may retrieve operator docs, command descriptors,
  settings descriptors, and runbook snippets.
- `memory_query` turns may retrieve durable memory, approved facts, and labelled
  episode working history.
- Ordinary task turns receive bounded RAG snippets only when the router posture
  or explicit user request justifies it.
- Staged memory and future staged ingestion records are searchable for explicit
  review surfaces but are not trusted prompt context.
- Future promoted ingestion records enter RAG through the durable-memory path.
- When vectors are healthy, default retrieval is hybrid vector plus FTS using
  reciprocal-rank fusion. When vectors are disabled or degraded, retrieval falls
  back to lexical FTS with an operator-visible warning.

## Consequences

**Positive**

- Help-like prompts can be answered from current operator docs instead of vague
  model memory.
- Future growth-loop ingestion has a retrieval substrate before it starts
  collecting new staged records.
- Local vector RAG works without a hosted provider.
- Lexical RAG remains available when vectors are disabled or degraded.
- Semantic retrieval grows from a memory-only seam into a cross-source service
  without removing the existing memory search contract.

**Negative**

- SQLite plus `sqlite-vec` and `rusqlite` add a dependency surface that needs
  version pinning and dependency-gate review.
- The system now has both Tantivy memory search and SQLite RAG until a later
  release decides whether consolidation is worth the migration cost.
- Real local embeddings require Ollama and an embedding model to be installed
  for full vector behavior.

**Neutral**

- Tantivy/BM25 remains the v0.5 curated-memory baseline.
- The v0.11 semantic-memory JSON seam may become a compatibility layer or be
  retired once the v0.15 RAG service owns vector retrieval.
- Future releases may switch the vector backend if official SQLite `vec1`
  matures enough to justify replacing `sqlite-vec`.
- Hosted embeddings may be added later through the same owned provider seam.

## Implementation note

M0 pins the first dependency proof in `allbert-kernel-services` with
`rusqlite` using bundled SQLite and the official `sqlite-vec` Rust crate. The
initial pin uses exact `sqlite-vec` `0.1.9`; the newer `0.1.10-alpha.3` package
failed the local build proof because its packaged C source referenced a missing
`sqlite-vec-diskann.c` include. This keeps the derived RAG store local and
rebuildable before the full store lands.

## References

- [docs/plans/v0.15-rag-recall-help.md](../plans/v0.15-rag-recall-help.md)
- [docs/plans/future-plans.md](../plans/future-plans.md)
- [ADR 0107](0107-rag-vectors-use-local-ollama-embeddings-and-sqlite-vec.md)
- [ADR 0108](0108-rag-indexing-is-daemon-maintained-and-channel-visible.md)
- [ADR 0045](0045-memory-index-is-a-derived-artifact-rebuilt-from-markdown-ground-truth.md)
- [ADR 0046](0046-v0-5-memory-retrieval-uses-tantivy.md)
- [ADR 0078](0078-semantic-memory-is-optional-derived-retrieval.md)
- [SQLite vec1](https://sqlite.org/vec1)
- [sqlite-vec Rust docs](https://alexgarcia.xyz/sqlite-vec/rust.html)
- [sqlite-vec KNN docs](https://alexgarcia.xyz/sqlite-vec/features/knn.html)
- [sqlite-vss](https://github.com/asg017/sqlite-vss)
- [Ollama embeddings](https://docs.ollama.com/capabilities/embeddings)
