# RAG

Allbert's RAG index is a local derived SQLite artifact for operator help,
command descriptions, settings descriptions, skill metadata, durable memory,
approved facts, and bounded session working history. The index can be deleted
and rebuilt from source truth.

v0.15 closeout now includes a release-blocking M7 collection model. In that
target design, existing Allbert-owned RAG sources are `system` collections, and
operator-created task/corpus RAG sources are explicit `user` collections in the
same derived SQLite database. User collection commands are documented here as
the M7 implementation target; they are not considered release-ready until the
M7 tests in the feature runbook pass.

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

## Collections

M7 adds logical collections to the RAG index:

- `system` collections: operator docs, commands, settings, skills, durable
  memory, facts, episodes, sessions, and staged-review sources. These preserve
  the existing v0.15 prompt rules.
- `user` collections: operator-created local file/directory or explicit web URL
  corpora for a task or session. These are never searched or injected by
  default.

Planned local terminal command shape:

```bash
allbert-cli rag collections list
allbert-cli rag collections show user <name>
allbert-cli rag collections create user <name> --source /trusted/path
allbert-cli rag collections create user <name> --source https://example.com/page
allbert-cli rag collections ingest user <name>
allbert-cli rag collections rebuild user <name> --vectors
allbert-cli rag search "question" --collection-type user --collection <name>
allbert-cli rag collections attach user <name>
allbert-cli rag collections delete user <name>
```

REPL/TUI should expose equivalent `/rag collections ...` commands. Telegram
remains read-only for collection status/search in v0.15 M7 and must not create,
ingest, rebuild, delete, or attach user collections.

User collection ingestion supports two source families in v0.15 M7:

- Local `file://` and `dir://` sources must stay inside trusted roots.
- URL sources are explicit HTTP(S) sources. HTTPS is the default. Plain HTTP
  requires an explicit degraded/insecure posture.

URL ingestion is exact-URL by default. Same-origin expansion requires an
explicit operator cap, such as crawl depth and page count. URL fetches use
GET/HEAD only, an Allbert user agent, content-type allowlists, byte/page/time
caps, robots.txt checks, redirect revalidation, and conditional refresh metadata
from ETag or Last-Modified when the server provides it. Unsupported schemes,
embedded credentials, localhost, loopback, link-local, private, multicast,
broadcast, and cloud-metadata targets are rejected before fetch and again after
each redirect.

Deleting a user collection deletes derived index rows, not local source files
or remote content.

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

Scheduled maintenance defaults to system collections. User collection rebuilds
are explicit in v0.15 M7 so a task corpus does not keep consuming indexing work
after the task is finished unless the operator asks for it.

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

In M7, `search_rag` also accepts collection filters. Omitted filters preserve
current system collection behavior. User collection results are available only
when the collection is explicitly attached to the task/session or directly
named by an operator-approved RAG skill/search request.

Durable memory and approved facts can enter ordinary RAG results. Pending
staged memory is review-only: it is not indexed by default, and even an explicit
staged-memory review index requires a review-only search path before snippets
are returned.

RAG results are evidence with source labels. They do not authorize actions,
change schedules, promote memory, or replace guarded tool policy.
