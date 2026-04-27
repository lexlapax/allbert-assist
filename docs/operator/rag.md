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

Inside daemon-backed channels, use `/rag status`, `/rag search <query>`,
`/rag rebuild [--stale-only] [--vectors]`, and `/rag gc [--dry-run]` in the
REPL/TUI. Telegram exposes `/rag status` and `/rag search <query>` only; rebuild
and GC stay on local terminal surfaces because they can be long-running.

## Posture

v0.15 supports real local vectors through Ollama embeddings and `sqlite-vec`.
If Ollama or the configured embedding model is unavailable, hybrid/vector search
degrades to SQLite FTS when `rag.vector.fallback_to_lexical` is enabled. Run
`ollama pull embeddinggemma` for the default local embedding model.

## Maintenance

The daemon owns RAG maintenance. It is not a prompt-authored scheduled job and
does not create markdown job definitions. Manual REPL/TUI rebuilds and scheduled
maintenance share one rebuild lock. If another rebuild is active, the new run is
coalesced instead of starting a second writer. Manual rebuilds report
progress/results on the requesting protocol v7 connection; automatic
startup/scheduled maintenance records daemon log and RAG status/run posture
without injecting unsolicited messages into unrelated turns.

When `[rag.index].auto_maintain` and `run_on_startup_if_missing` are enabled,
the daemon starts one lexical-first rebuild if `rag.sqlite` is missing. When
`schedule_enabled` is enabled, the daemon runs at most one stale-only rebuild
per `@daily at HH:MM` window and does not replay missed windows after sleep or
shutdown. Scheduled runs include vectors when `[rag.vector].enabled` is true;
if Ollama is unavailable, lexical search remains usable and the vector posture
is reported as degraded or stale.

Protocol v7 carries `RagStatus`, `RagSearch`, `RagRebuildStart`,
`RagRebuildCancel`, and `RagGc` requests plus status, search, rebuild progress,
finished/cancelled/error, and GC result responses. Older v2-v6 clients can still
attach but do not receive v7-only RAG messages.

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
