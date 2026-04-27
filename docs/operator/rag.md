# RAG

Allbert's RAG index is a local derived SQLite artifact for operator help,
command descriptions, settings descriptions, and skill metadata. The index can
be deleted and rebuilt from source truth.

## Commands

Use `allbert-cli rag rebuild --no-vectors` to rebuild the lexical index.
Use `allbert-cli rag status` to inspect source and chunk counts.
Use `allbert-cli rag search <query>` to search bounded snippets.
Use `allbert-cli rag doctor` when the index is missing or appears stale.

## Posture

v0.15 M1 is lexical-only. Vector indexing and Ollama embeddings land in M2, so
M1 reports vectors as disabled or stale while keeping SQLite FTS usable.

RAG results are evidence with source labels. They do not authorize actions,
change schedules, promote memory, or replace guarded tool policy.
