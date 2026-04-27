# RAG

Allbert's RAG index is a local derived SQLite artifact for operator help,
command descriptions, settings descriptions, and skill metadata. The index can
be deleted and rebuilt from source truth.

## Commands

Use `allbert-cli rag rebuild --no-vectors` to rebuild the lexical index.
Use `allbert-cli rag rebuild --vectors` to build vectors when `[rag.vector]`
is enabled.
Use `allbert-cli rag status` to inspect source and chunk counts.
Use `allbert-cli rag search <query> --mode hybrid` to search bounded snippets
with vector/lexical fusion when vectors are healthy.
Use `allbert-cli rag doctor` when the index is missing or appears stale.

## Posture

v0.15 M2 supports real local vectors through Ollama embeddings and
`sqlite-vec`. If Ollama or the configured embedding model is unavailable,
hybrid/vector search degrades to SQLite FTS when `rag.vector.fallback_to_lexical`
is enabled. Run `ollama pull embeddinggemma` for the default local embedding
model.

RAG results are evidence with source labels. They do not authorize actions,
change schedules, promote memory, or replace guarded tool policy.
