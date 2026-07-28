# ADR 0092: Search Central And Conversation FTS

## Status

Proposed (v1.3, operator-signed readiness decision 2026-07-28). Binding on the
Search Central milestone in the v1.3 plan; flips Accepted when the central API,
canonical re-authorization, generation lifecycle, recurring maintenance,
surface scope rows, and packaged native-runtime proof are green.

This ADR supersedes ADR 0089 §6's conditional external-content FTS design.
Search ships as a central read product and point milestone without becoming a
Memory authority or displacing Long-Term User Memory as the v1.3 flagship.

Related: ADR 0002 (canonical records versus projections), ADR 0006 (Security
Central), ADR 0016/0057 (channel identity/thread scope), ADR 0070/0073
(registered reads and thin surfaces), ADR 0076 (per-target packaged native
runtime), ADR 0089 (Memory collection/consent), and ADR 0091 (thin TUI consumes
the same API).

## Context

Conversation history is durable SQLite data but has no bounded full-text search.
Adding search independently to Web, TUI, CLI, and messaging adapters would
duplicate ranking, scope, disclosure, redaction, and stale-result behavior.
Using the search index itself as authority would also let an old row outlive a
canonical deletion or identity-policy change.

SQLite FTS5 is already available through the project's Exqlite dependency, but
the loaded target NIF—not a developer's `sqlite3` CLI or a vendored header—is
the acceptance boundary. A separate search database cannot directly use a
table in the canonical database as an FTS external-content table: SQLite
requires that external content live in the same database. Mirroring canonical
rows into a second content table plus triggers would create another
synchronization system without adding authority.

## Decision

### 1. One central typed Search API for every surface

`AllbertAssist.Search` is the sole surface-facing **conversation** search
context. It exposes a typed query/page/error contract and one registered read
action through `Actions.Registry` and `Actions.Runner.run/3`. Web, TUI, CLI,
mapped DMs, and later surfaces adapt input and render the same result DTO; none
opens the FTS database, constructs SQL, ranks rows, or applies scope locally.

The qualifier is load-bearing. The existing `search_memory` registered action
(`actions/memory/search_memory.ex`, reached from `cli/areas/memory.ex`) searches
Memory claims, not conversations, and continues to do so; an unqualified "sole
surface-facing search engine" claim would have been false at merge. The two are
different corpora with different authority models — claims are operator-curated
and enter prompts, conversation rows are canonical history that never does — and
the operator documentation names both.

Result DTOs, the query grammar, and scope filters carry a `source_type`
dimension from this first version, fixed to conversation in v1.3. Notes and
files already ship as local knowledge and are the plausible second corpus;
without the dimension present from the start, adding one later would be a
breaking change to a Tier-2 contract instead of an additive one. Reserving the
dimension is not a commitment to index anything else in v1.3.

`AllbertAssist.Conversations.Corpus` is the canonical conversation authority.
It classifies source visibility and principal/surface/thread eligibility,
streams indexable documents, and re-authorizes candidates. Search Central is an
advisory read projection. If its index is missing, rebuilding, corrupt, or
unavailable, it returns a typed unavailable/retryable result. It does not fall
back to an unbounded scan of canonical conversation tables.

### 2. A separate disposable plaintext database

Search uses a dedicated plaintext `search.sqlite3` under Allbert Home, separate
from the canonical Repo database and excluded from authoritative backups. It is
safe to delete and rebuild. The database contains:

- one ordinary **content-storing** FTS5 table with indexed text plus unindexed
  stable source id, canonical digest, timestamp, and scope/classification
  fields; and
- the minimum generation/schema/tokenizer/source-watermark metadata needed to
  verify and promote a generation.

It does not use external-content FTS, a duplicate local content table with
triggers, or cross-database transaction claims. Text duplication is accepted
inside this disposable projection because it removes a second synchronization
mechanism. SQLite WAL improves reader/writer concurrency but still permits only
one writer for this database.

No SQLCipher or new encryption/key-management layer is added. The canonical
conversation store is already plaintext under the local Allbert-Home trust
boundary; encrypting only its disposable projection would add overhead without
protecting the source. An E2EE-origin adapter is excluded by default and may be
indexed only through a separately audited opt-in that clearly discloses that
eligible message text will have a local plaintext search projection.

### 3. Corpus eligibility is explicit and narrower than raw storage

The ordinary index contains only canonically visible operator and assistant
conversation messages. Hidden system prompts, tool/model logs, internal action
payloads, secrets, deleted/hidden rows, and non-conversation trace material are
excluded. Index ingestion accepts only typed Corpus documents; an arbitrary
role or surface-supplied map cannot become searchable.

Every candidate is re-read or re-authorized through
`Conversations.Corpus` immediately before return. A missing/deleted source,
changed canonical digest, identity remap, visibility change, or scope denial
drops the hit. The index never grants access merely because it still contains
text.

Canonical retention remains unchanged. Canonical conversation deletion is in
v1.3 scope and becomes an input to reconciliation/purge; Search Central does
not invent a separate canonical retention policy.

### 4. Deliberately lexical query and deterministic page contract

The tokenizer is FTS5 `unicode61 remove_diacritics 2`. The API builds a small
safe grammar of lexical terms, quoted phrases, and explicit suffix-prefix
queries. SQL is parameterized and surfaces never pass arbitrary raw FTS syntax.
Fuzzy matching, trigram/substring search, semantic/vector retrieval, stemming
expansion, and learned ranking are out.

The total ordering tuples are fixed: `relevance` is `(bm25 ASC, timestamp DESC,
source_id ASC)`, `newest` is `(timestamp DESC, source_id ASC)`, and `oldest` is
`(timestamp ASC, source_id ASC)`. FTS5's numerically lower BM25 score is the
better match. Scores are meaningful only within one index revision; ingestion
can change collection statistics and therefore rank.

Every committed ingestion/reconciliation mutation increments a monotonic
projection revision in the current generation. Pagination cursors are opaque
and bind at least the generation id, projection revision, normalized
query/scope/order digest, and final ordering position. A cursor for a retired
or mismatched generation/revision returns a typed stale-cursor error; it is not
silently rebased onto differently ranked results after BM25 collection
statistics change.

### 5. Surface policy is centralized and transport-aware

- Verified local Web, TUI, and CLI operator surfaces are eligible to search all
  history authorized to the local operator.
- A verified mapped one-to-one operator DM defaults to its current
  channel/thread. A request for cross-thread or cross-surface history requires
  an explicit Security Central confirmation before any broader result is
  returned.
- Group/shared, programmatic, unknown, and unmapped callers are excluded from
  Search in v1.3; transport or model output cannot elevate them.
- E2EE-origin text requires the separate projection opt-in from §2 even when
  identity otherwise maps to the operator.

Memory's `CollectionPolicy` and Search policy remain distinct. Eligibility to
search an assistant-visible message does not make that message eligible to
originate a Memory fact. Search private/E2EE grants cannot authorize Memory
collection, and Memory private/E2EE grants cannot authorize Search projection.

### 6. Verified generations, not in-place best-effort rebuilds

Incremental indexing/reconciliation uses the current generation and one writer.
A full rebuild writes a new same-directory generation file, records its source
watermark and configuration, and verifies SQLite integrity, FTS integrity,
expected eligibility/digest samples, schema/tokenizer version, and an actual
create/insert/query smoke before promotion.

Only a verified generation may be promoted. Promotion uses same-filesystem
namespace rename only after `PRAGMA wal_checkpoint(TRUNCATE)` returns
`busy = 0`, the builder connection closes, and a self-contained reopen plus
integrity/query check proves no required `-wal`/`-shm` sidecar.

The Memory projection needs this identical sequence, so the checkpoint → close
→ self-contained reopen → integrity proof → atomic promote → retain-previous
steps live in one small shared private helper rather than being written twice
(v1.3 plan LD 62). Each domain keeps its own schema, verification predicates,
generation metadata, and rebuild source; only the promote sequence is shared.
This is not the generic projection framework the plan's complexity budget
excludes — it is deduplication of the one subtle sequence whose failure mode is
silent data loss. It retains
`current` plus one `previous`
verified generation and leaves the current generation untouched on
build/verification failure.
Startup selects a valid current generation or recovers the previous one and
reports the degraded state. Atomic rename is a namespace guarantee on supported
POSIX targets, not a claim of crash-durable storage; retained previous state and
startup verification provide recovery.

### 7. Existing recurring Jobs own ingestion and maintenance

Search adds no private scheduler. One small `Jobs.Managed` helper generalizes
the existing managed-job sync pattern, and Search Central owns exactly three
ordinary recurring-engine entries:

1. bounded incremental index/reconcile, with a durable canonical watermark;
2. weekly bounded maintenance: prune/reconcile, FTS segment merge, integrity
   check, and recorded health summary; and
3. a paused/manual full rebuild entry used for repair and generation changes.

One Search feature setting governs the ordinary local managed set; the operator
does not consent to each internal maintenance entry separately. Scope
expansions such as E2EE projection remain separately opted in.

That feature setting **defaults on for local Web, CLI, and TUI**, so a fresh
Home can search its own history without first discovering a switch. Mapped
operator DMs and E2EE origins remain behind their separate grants. This is
deliberately asymmetric with Memory's `memory.consolidation.enabled`, which
defaults false: Search is local, read-only, produces no proposals, injects
nothing into any prompt, and its entire database can be deleted and rebuilt,
whereas Memory collection derives durable new claims about the operator.
Indexing what the operator already wrote, for their own retrieval, is a
different act from concluding things about them. Both defaults are stated
together wherever either is documented. Jobs are
idempotent, serialize the search writer, use bounded batches, expose
watermark/lag/generation/counts without content, and never hold the canonical
Repo and search writer in a claimed cross-database atomic transaction.

Weekly work uses bounded FTS merge steps rather than a routinely unbounded
`optimize`. Full optimization may occur only as measured manual rebuild
closeout.

### 8. Purge is separately confirmed and honestly best-effort

Ordinary reconciliation removes rows no longer eligible in the canonical
Corpus. An operator-requested Search purge is a separate confirmed action. Its
affected canonical content must already be deleted/ineligible, or the affected
Search source class/feature must first be disabled; otherwise the action fails
its precondition because recurring ingestion would restore the text. Purge
covers every Search-owned current, previous, build-temporary, failed, retired,
or pending-prune database plus its `-wal`/`-shm` sidecars. No openable or
startup-recoverable managed SQLite generation may retain the purged text.
Memory Forget remains ADR 0089's distinct action.

For files that can be opened it combines FTS5 `secure-delete=1`, core
`PRAGMA secure_delete=ON`, `wal_checkpoint(TRUNCATE)` with `busy = 0`, and
`VACUUM` where the measured deletion path requires it and disk/lock
preconditions allow. Because enabling FTS secure-delete cannot remove older
tombstoned terms retroactively, any generation that may contain historical
deletes is replaced from the currently eligible canonical set; obsolete and
failed generations are deleted wholesale. The replacement is closed,
self-contained-reopened, integrity/query checked, and searched for the purged
fixtures before success. Failure remains visible and does not produce a false
“purged” result. This is best effort for every Allbert-managed Search SQLite
file and sidecar in the confirmed scope; it does not promise erasure from
backups, snapshots, exported copies, filesystem remnants, or SSD wear leveling.

### 9. Search does not silently enter prompts or Memory

Ordinary search returns a result page to the requesting surface. It is never
automatically injected into Runtime prompts, Active Memory, consolidation, or
model context. An explicit operator summarize action may submit a selected,
re-authorized result set to the model for that response only. It creates no
Memory proposal and no Search-to-Memory promotion path exists.

Query text, snippets, and filter operand values are not written to traces or
audits. Trace-safe metadata may record query id, verified principal/surface,
policy scope class, generation/revision, ordering mode, filter kinds/count,
result/filtered counts, duration band, confirmation outcome, and error class.

## Consequences

- Every surface receives one ranking, scope, stale-row, disclosure, and paging
  contract instead of implementing search locally.
- The canonical conversation database remains the authority; the FTS database
  can be deleted, rebuilt, and excluded from authoritative backup/restore.
- Query-time re-authorization makes index lag fail closed for disclosure, while
  the absence of a canonical-scan fallback keeps latency and load bounded.
- A plaintext projection and one small managed-job helper avoid an encryption
  subsystem, trigger mirror, or parallel scheduler.
- Current/previous verified generations make rebuild and rollback additive
  without pretending that cross-database operations or rename are crash-durable.

## Non-goals And Guardrails

- No external-content table across database files, trigger-maintained mirror,
  or second canonical history store.
- No claim that Search replaces `search_memory`; Memory-claim search stays a
  separate corpus with its own action.
- No second writer to any Search database file, and no cross-database
  transaction with the canonical Repo or the Memory projection.
- No raw FTS query language at a surface; no fuzzy, trigram, semantic, vector,
  or learned-ranking search.
- No search-result authority, implicit cross-surface DM disclosure,
  Search-to-Memory promotion, or default prompt injection.
- No SQLCipher/new encryption layer and no claim that filesystem permissions
  or a local token are an OS security boundary.
- No canonical retention rewrite, automatic conversation deletion, or forensic
  erasure guarantee.
- No concurrent-writer or cross-database atomicity claim.

## Validation

Acceptance proves, against the native SQLite library loaded by each packaged
target:

- `SELECT sqlite_version()`, `PRAGMA compile_options`, FTS5
  create/insert/phrase/prefix/query, tokenizer behavior, rank ties, cursor
  generation/revision binding, and secure-delete/checkpoint behavior;
- index eligibility and query-time drop for deletion, digest drift, identity
  remap, visibility change, hidden/tool/system/secret/action-log rows, and scope
  denial, including absence from every current/previous/build-temporary/failed/
  retired/pending-prune database and sidecar state;
- local Web/TUI/CLI parity, mapped-DM same-thread default, confirmed scope
  elevation, E2EE opt-in/disclosure, and no query/snippet audit leakage;
- bounded reconcile/weekly/manual jobs, one-writer behavior, failed-generation
  non-promotion, `busy = 0` checkpoint/close/self-contained reopen promotion,
  previous-generation recovery, purge across every Search-owned generation/
  database/sidecar state including historical-delete rebuild, purge
  precondition denial, authoritative export/backup exclusion with restore
  rebuild, and no canonical scan fallback;
  and
- ordinary search isolation from model/Memory plus the explicit summarize-only
  path.

Primary SQLite evidence: [FTS5](https://www.sqlite.org/fts5.html),
[external-content constraints](https://www.sqlite.org/fts5.html#external_content_tables),
[`unicode61`](https://www.sqlite.org/fts5.html#unicode61_tokenizer),
[BM25](https://www.sqlite.org/fts5.html#the_bm25_function),
[WAL](https://www.sqlite.org/wal.html),
[FTS secure-delete](https://www.sqlite.org/fts5.html#the_secure_delete_configuration_option),
[core secure-delete](https://www.sqlite.org/pragma.html#pragma_secure_delete),
[WAL checkpoint](https://www.sqlite.org/pragma.html#pragma_wal_checkpoint), and
[`VACUUM`](https://www.sqlite.org/lang_vacuum.html). Same-filesystem rename
semantics come from
[POSIX `rename`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
