# RAG

Allbert's RAG index is a local derived SQLite artifact for operator help,
command descriptions, settings descriptions, skill metadata, durable memory,
approved facts, and bounded session working history. The index can be deleted
and rebuilt from source truth.

## Commands

Use `allbert-cli rag rebuild --no-vectors` to rebuild the lexical index.
Use `allbert-cli rag rebuild --vectors` to build vectors when `[rag.vector]`
is enabled.
Use `allbert-cli rag status` to inspect source and chunk counts.
Use `allbert-cli rag search <query> --mode hybrid` to search bounded snippets
with vector/lexical fusion when vectors are healthy.
Use `allbert-cli rag doctor` when the index is missing or appears stale.

## Posture

v0.15 supports real local vectors through Ollama embeddings and `sqlite-vec`.
If Ollama or the configured embedding model is unavailable, hybrid/vector search
degrades to SQLite FTS when `rag.vector.fallback_to_lexical` is enabled. Run
`ollama pull embeddinggemma` for the default local embedding model.

## Prompt Use

RAG is not a separate agent. The kernel uses it in bounded places in the normal
turn loop:

- before the router, a tiny lexical hint may search only operator docs,
  commands, settings, and bounded skill metadata;
- after the router, eligible help/meta turns retrieve docs, commands, settings,
  and skills, while memory-query turns retrieve durable memory, approved facts,
  episode recall, and session summaries;
- task turns retrieve only when the prompt or tool evidence asks for local
  context, and ordinary chat usually skips RAG;
- rendered snippets are labelled evidence with source ids, not authority.

The root model also has a read-only `search_rag` tool for a capped second
retrieval pass. It cannot mutate memory, schedules, settings, or the index, and
review-only staged memory remains unavailable outside explicit review context.

Durable memory and approved facts can enter ordinary RAG results. Pending
staged memory is review-only: it is not indexed by default, and even an explicit
staged-memory review index requires a review-only search path before snippets
are returned.

RAG results are evidence with source labels. They do not authorize actions,
change schedules, promote memory, or replace guarded tool policy.
