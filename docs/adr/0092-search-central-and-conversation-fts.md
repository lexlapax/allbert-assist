# ADR 0092: Search Central And Conversation FTS

## Status

Accepted (v1.3, 2026-08-04). The central API, canonical re-authorization,
generation lifecycle, recurring maintenance, surface scope rows, and packaged
native-runtime proof are green.
M1 froze the numeric query, paging, drain, scale, latency, and capability
contracts on 2026-07-29. M6 subsequently made the central API, canonical
candidate reauthorization, trace-safe request path, loaded-Exqlite capability
probe, and verified current/previous generation lifecycle focused-gate green.
M7 subsequently made the three Jobs-owned management entries, dirty repair,
bounded maintenance/rebuild, stale reconciliation, authoritative-export
exclusion, and confirmed crash-resumable all-generation purge focused-gate
green. M8 made the shared Web/TUI/CLI/DM consumer, deterministic source-linked
presentation, durable direct/shared/unknown transport-scope proof, exact
confirmation/resubmit behavior, and cross-consumer security rows focused-gate
green. M9 added the loaded-Exqlite packaged capability smoke and an executable
25,000-message/250-thread/300-query latency harness. Final replacement
published generation `v13-20260805T170225Z-bc584c295f74` ran the capability
smoke from all three native archives. The four clean packaged latency cells are
recorded separately in `docs/validation/test-metrics/summary.md`: macOS arm64
Search p95/p99 `64.013/67.064 ms`, Linux x64 Search `48.192/52.278 ms`, macOS
arm64 Memory `52.860/55.265 ms`, and Linux x64 Memory `38.271/38.775 ms`. Every
row binds full accepted source SHA
`bc584c295f74700de485530ecdc70fe5792e6421` and its target archive digest; no
source-tree probe, superseded provisional package, or cross-host average is
substituted.

**Implementation correction noted 2026-08-05 (v1.3.1, operator-signed).** The
shipped `Jobs.Managed.apply_kick/1` could retain `status: paused` yet repopulate
`next_due_at`, diverging from the already-accepted §7 contract below. v1.3.1
centralizes effective-due calculation so paused/disabled managed rows keep a
nil due while dirty intent survives; resume computes one catch-up opportunity.
This enforces the accepted decision for every managed identity and adds no
scheduler or Search-specific exception.

This ADR supersedes ADR 0089 §6's conditional external-content FTS design.
Search ships as a central read product and point milestone without becoming a
Memory authority or displacing Long-Term User Memory as the v1.3 flagship.

The operator-signed final readiness pass makes origin-scoped grants,
per-message origin evidence, Jobs-owned dirty wakeups and atomic admission,
policy-bound repair/rebuild epochs, post-authorization page refill, trace-safe
query confirmation, bootstrap, and canonical delete targets binding. These
additions close execution ambiguity without adding a scheduler, encryption
layer, deletion ledger, query-grant store, or generic projection framework.

The fifth readiness pass moved the canonical conversation delete contract out of
§3 into **ADR 0093**: deleting the operator's history is a Corpus-owned
destructive capability, and this ADR keeps only the reconciliation-input
relationship to it.

Related: ADR 0002 (canonical records versus projections), ADR 0006 (Security
Central), ADR 0016/0057 (channel identity/thread scope), ADR 0093 (canonical
conversation deletion — the input Search reconciles against), ADR 0070/0073
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
M8 materializes that adapter seam as one `AllbertAssist.Search.Surface` closed
command parser/dispatcher plus one transport-neutral
`AllbertAssist.Search.Presentation` renderer. Surfaces may supply authenticated
identity/origin context and display the returned DTO; they do not gain an
alternative query or policy path.

The qualifier is load-bearing. The existing `search_memory` registered action
(`actions/memory/search_memory.ex`, reached from `cli/areas/memory.ex`) searches
Memory claims, not conversations, and continues to do so; an unqualified "sole
surface-facing search engine" claim would have been false at merge. The two are
different corpora with different authority models — claims are operator-curated
and enter prompts, conversation rows are canonical history that never does — and
the operator documentation names both.

Result DTOs may carry the optional constant `source_type: :conversation` as an
additive discriminator. The v1.3 query/filter grammar does not branch on
speculative corpora; another source type requires a separately accepted corpus
adapter and can extend the optional field additively. Notes and files are not
committed by this reservation.

M1 freezes schema version `1`. The request is `%{query: String.t(), order:
:relevance | :newest | :oldest, limit: 1..100, cursor: nil | String.t(),
filters: map(), query_chain_id: nil | String.t()}`. Closed filters are
`authors` (operator/assistant), at most eight `surfaces`, at most eight
`thread_ids`, nullable UTC-microsecond `after`/`before`, base `origin_scope`,
and nullable `e2ee`; unknown keys fail. The parser accepts Unicode words,
double-quoted phrases, and trailing `*` only on a prefix of at least two Unicode
codepoints. Operators, parentheses, column selectors, embedded wildcards, and
raw FTS punctuation fail validation. Filters are ANDed and list values are
ORed.

The page result is `%{results, next_cursor, generation_id,
projection_revision, indexed_through, freshness_ms, scanned_count,
filtered_count, incomplete, incomplete_reason}`. Each item contains source and
thread ids, author/trust/surface/timestamp, authorized snippet, lexical score,
generation/revision, and optional constant `source_type`. Closed errors are
`:invalid_query | :invalid_filter | :invalid_limit | :search_disabled |
:search_not_ready | :search_changed | :scope_denied |
:query_confirmation_required | :query_resubmit_required |
:query_chain_expired`. Cursors are
`allbert.search.cursor.v1:<base64url-payload>.<base64url-tag>` and contain no
plain query/filter material.

`AllbertAssist.Conversations.Corpus` is the canonical conversation authority.
It classifies source visibility and principal/surface/thread eligibility,
streams indexable documents, and re-authorizes candidates. Search Central is an
advisory read projection. If its index is missing, rebuilding, corrupt, or
unavailable, it returns a typed unavailable/retryable result. It does not fall
back to an unbounded scan of canonical conversation tables.

### 2. A separate disposable plaintext database

Search uses dedicated plaintext generation files under
`<ALLBERT_HOME>/projections/search/`, separate from the canonical Repo database
and excluded from authoritative backups. The fixed names are `control.json`,
`current.sqlite3`, `previous.sqlite3`, and at most one live
`build-<UUIDv7>.sqlite3` plus SQLite sidecars. No symlink/pointer service selects
a generation. The files are safe to delete and rebuild. Each generation
contains:

- one ordinary **content-storing** FTS5 table whose rowid identifies the
  searchable redacted text;
- one ordinary content-free locator table with `fts_rowid INTEGER PRIMARY KEY`,
  a unique `(source_type, source_id)`, canonical source version/digest, timestamp
  in one frozen integer unit, author/origin/surface/channel/thread/trust/source-
  class fields, and the projection-revision fields needed by repair; and
- the minimum generation/schema/tokenizer/redactor/source-watermark metadata
  needed to verify and promote a generation.

The schema-1 names/columns are closed. `documents` has `fts_rowid INTEGER
PRIMARY KEY`; required `source_type`, `source_id`, `thread_id`, `author`,
`trust`, `surface`, `thread_kind`, `origin_scope`, `e2ee`, `timestamp_us`,
`source_version`, `content_digest`, `redactor_version`, `tokenizer_version`,
`schema_version`, and immutable `first_projected_revision`; plus nullable remote
`owner_scope`, `channel`, `receiver_account_ref`, and `provider_thread_key`.
`source_type` is `conversation`, `author` is `operator | assistant`, `e2ee` is
`0 | 1`, `timestamp_us` is Unix microseconds, and versions/revisions are non-
negative integers. `search_fts` is content-storing
`fts5(searchable_text, tokenize='unicode61 remove_diacritics 2')` sharing the
same rowid. One-row `generation_meta` mirrors LD 84's immutable generation id,
compatibility versions, source high-water, eligibility epoch, and projection
revision. No other content column or source-adapter table ships in v1.3.

The locator, not an FTS `UNINDEXED` column, owns uniqueness, exact source lookup,
typed-filter metadata, and deterministic chronological tie-break fields. SQLite
virtual tables cannot receive normal secondary indexes, so M1 froze the small
set of locator B-tree indexes required by the shipped filters/orders. Projection
upsert/delete mutates the locator, FTS row, and generation revision/watermark in
one Search-database transaction. It preserves the integer rowid for an existing
source and verifies a one-to-one locator/FTS pairing. No second table duplicates
message text.

It does not use external-content FTS, a duplicate local content table with
triggers, or cross-database transaction claims. Text storage inside the FTS
table is accepted because it removes a second content synchronization
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

Remote source scope is per message, not inferred from canonical-thread
membership. An admitted remote operator message binds the exact canonical
thread-channel reference plus an immutable normalized origin-principal digest
and version. An assistant message produced for that request persists a
versioned, server-derived origin tuple — `owner_scope`, channel,
`receiver_account_ref`, `provider_thread_key`, and canonical thread — from the
verified admitted request. Caller-supplied message metadata cannot manufacture
that evidence. A mapped-DM default-scope match requires the whole current origin
tuple **and** canonical thread to match. This prevents a canonical thread that
has been resumed or linked across surfaces from laundering local or another
channel's history into the DM. Historical remote assistant rows whose exact
origin cannot be proved are `legacy_origin_unverified`: local all-history Search
may return them after ordinary canonical authorization, but mapped-DM default
scope may not.

Deterministic Search result-render turns carry a typed action/result marker and
are excluded from the Search projection. Their canonical conversation/provider
copies remain subject to ordinary retention, but snippets are not recursively
indexed as new same-channel search sources.

Every candidate is re-read or re-authorized through
`Conversations.Corpus` immediately before return. A missing/deleted source,
changed canonical digest, identity remap, visibility change, or scope denial
drops the hit. The index never grants access merely because it still contains
text.

Canonical retention remains unchanged, and Search Central does not own it.
v1.3 adds the separately confirmed, registered `delete_conversation_content`
action with `target_kind: message | thread`; its preview binding, exact
conversation-owned cascade, live-dependency blocking, survivor disclosure, and
crash-safe idempotency are specified in **ADR 0093**, and it is built by the
Corpus workstream. Deleting the operator's history is a destructive capability
over canonical user data, not a search concern.

Search consumes deletion only as a reconciliation input: the action commits
canonically first, Corpus immediately reports the source missing or ineligible
so query-time reauthorization covers the repair interval, and the action marks
Search dirty for ordinary reconciliation. Search Central invents no separate
canonical retention policy and never claims canonical deletion merely because
an index row was removed.

### 4. Deliberately lexical query and deterministic page contract

The tokenizer is FTS5 `unicode61 remove_diacritics 2`. The API builds a small
safe grammar of lexical terms, quoted phrases, and explicit suffix-prefix
queries. SQL is parameterized and surfaces never pass arbitrary raw FTS syntax.
Fuzzy matching, trigram/substring search, semantic/vector retrieval, stemming
expansion, and learned ranking are out.

The total ordering tuples are fixed: `relevance` is `(bm25 ASC, timestamp_us
DESC, source_id ASC)`, `newest` is `(timestamp_us DESC, source_id ASC)`, and
`oldest` is `(timestamp_us ASC, source_id ASC)`. `timestamp_us` is Unix
microseconds and the result DTO converts it to a UTC-microsecond timestamp.
FTS5's numerically lower BM25 score is the
better match. Scores are meaningful only within one index revision; ingestion
can change collection statistics and therefore rank.

Every committed ingestion/reconciliation mutation increments a monotonic
projection revision in the current generation. Pagination cursors are opaque
and bind at least the generation id, projection revision, a domain-separated
keyed normalized-request/scope/order binding, and final scanned ordering
position plus non-secret key ref/version. The authenticated cursor uses
`allbert.search.cursor.v1` with shared Key Custody ref
`secret://system/integrity_v1` (record version `1`) and exposes no plain query/
filter digest. The TUI milestone owns the additive system-secret
`fetch_or_create` seam; Search creates no key service or additional Home key. A
cursor for a retired or mismatched generation/revision returns a typed stale-cursor
error; it is not silently rebased onto differently ranked results after BM25
collection statistics change.

Every Search/delete binding uses ADR 0091's shared two-step domain-key helper
and canonical length-prefixed encoding. Search never handles the raw Home key
outside that helper.

Authorization filtering cannot underfill a page merely because stale or
ineligible hits lead the ranking. Search overfetches candidates in 100-row
batches, re-authorizes each through Corpus, and continues until the requested
page is full, the generation is exhausted, or 500 candidates/5 batches are
reached. The cursor records the last **scanned** ordering tuple, not the last
returned tuple, so filtered rows cannot loop or skip later eligible rows. The
typed result includes scanned/filtered counts and an `incomplete` reason when
the scan budget—not end of results—stops refill. Every surface receives this
same behavior.

M1 froze the implementation bounds: candidate batches contain `100` rows and
one page scans at most `500` candidates/`5` batches. Query text is at most
`1_024` UTF-8 bytes, `16` lexical clauses, one phrase of at most `12` tokens,
and `8` typed filters. Default result limit is `20`, maximum `100`; each result
has one snippet whose Settings Central byte bound defaults to `320` and accepts
`64..1024`. Over-limit queries fail validation rather than being truncated.
Mapped-DM cross-surface approval expires after exactly `300` seconds and page
cursors cannot extend it. Promotion drains admitted readers for at most `2_000`
milliseconds.

The ordinary locator owns exactly these B-tree indexes: unique `(source_type,
source_id)`; both `(timestamp_us DESC, source_id ASC)` and `(timestamp_us ASC,
source_id ASC)`; timestamp/source-id indexes prefixed individually by
`thread_id`, `author`, and `surface`; and `(origin_scope, e2ee, timestamp DESC,
source_id ASC)`. Compound filters use bounded locator intersection rather than
an index-per-combination design. The E2EE boolean is separate because
`e2ee_operator` is an overlay on, not a replacement for, the local or mapped-DM
base origin.

The release scale is `25_000` messages across at least `250` threads with at
least `256` average UTF-8 bytes. After one unmeasured warm pass, query plus
Corpus reauthorization across `300` mixed queries is p95 `<= 200 ms` and p99
`<= 750 ms`, recorded separately on the packaged macOS arm64 operator host and
packaged Linux x86_64 Serenity host. Normal dirty ingestion is visible within
`90` seconds; hourly reconciliation is the missed-wakeup bound.

### 5. Surface policy is centralized and transport-aware

- Verified local Web, TUI, and CLI operator surfaces use the implicit/default-
  on Search grant for origin scope `local_operator` and may search all history
  authorized to the local operator.
- A verified mapped one-to-one operator DM requires one Search-consumer grant
  for origin scope `mapped_operator_dm`; that one grant covers current and
  future verified mapped 1:1 DMs, not one prompt per channel. Query scope still
  defaults to the intersection of the current canonical thread and the exact
  current per-message origin tuple from §3. Canonical-thread membership,
  channel name, or receiver account alone is insufficient. The canonical
  thread ref must also carry adapter-derived `conversation_scope: direct`;
  `shared` and `unknown` fail closed. This is separate from, and does not add a
  field to, the exact per-message origin tuple. Cross-thread or
  cross-surface history requires a second Security Central confirmation for
  exactly one normalized query/cursor chain with 300-second expiry.

  The registered `authorize_search_query_scope` action is `resumable?: true`
  and is explicitly allowlisted through the existing generic confirmation-
  resume path. Its safe resume parameters contain the verified principal,
  exact origin tuple, requested scope, expiry, source message id, safe filter
  kinds/count, non-secret key ref/version, and an
  `allbert.search.query-scope.v1` keyed request binding—not query text,
  plain query/filter digests, operands, MATCH syntax, or snippets. Approval
  invokes only this authorization action and returns
  `query_resubmit_required`; it never executes the Search query from stored
  confirmation state. The resolved confirmation id itself is the
  `query_chain_id`, so no second query-grant table or index exists.

  The client or DM adapter resubmits the exact transient request with that
  confirmation id. An adapter may rehydrate the canonical source message by
  id for this resubmission, but Search recomputes and verifies the keyed binding
  against the still-current principal, origin, scope, expiry, and request before
  admission; a missing or changed source is stale. Cursors bind that same
  resolved confirmation and may paginate without another prompt until expiry,
  scope change, or query-chain termination. A generation/revision change
  invalidates the page cursor but permits an exact page-one resubmission under
  the same still-valid query-chain binding; it does not manufacture or extend
  another approval.
- Group/shared, programmatic, unknown, and unmapped callers are excluded from
  Search in v1.3; transport or model output cannot elevate them.
- E2EE-origin text requires the separate projection opt-in from §2 even when
  identity otherwise maps to the operator.

Memory's `CollectionPolicy` and Search policy remain distinct consumer grants.
The verified `private_operator` trust class alone grants neither. Eligibility to
search an assistant-visible message does not make that message eligible to
originate a Memory fact. Search private/E2EE grants cannot authorize Memory
collection, and Memory private/E2EE grants cannot authorize Search projection.
Canonical deletion, lost canonical visibility, or principal invalidation
suppresses both consumers; Search-only revocation does not stale Memory
proposals, and Memory-only revocation does not remove otherwise eligible Search
rows.

### 6. Verified generations, not in-place best-effort rebuilds

Incremental indexing/reconciliation uses the current generation and one writer.
A full rebuild writes a new same-directory generation file, records its source
watermark and configuration, and verifies SQLite integrity, FTS integrity,
expected eligibility/digest samples, schema/tokenizer version, and an actual
create/insert/query smoke before promotion.

`Conversations.Corpus` exposes two independent durable monotonic boundaries:
the source high-water used to bound ordered ingestion and an
`eligibility_epoch` used to invalidate work whose authorization population can
shrink or move. Ordinary appends advance the source high-water and leave dirty
work; they do not churn the eligibility epoch. Canonical deletion, visibility
change, identity/principal remap or invalidation, Search-consumer grant
revocation, and E2EE projection opt-out advance the eligibility epoch in the
owning authority's mutation path. Schema, tokenizer, and redactor versions are
separate generation-compatibility inputs rather than disguised source
watermarks.

Each reconciliation/repair run freezes its starting source high-water,
eligibility epoch, projection revision, configuration versions, and starting
index population. Its sweep removes only rows from that starting population;
canonical writes after the high-water remain dirty for the next bounded run and
cannot be swept as "missing." A full builder carries the same boundaries and
must re-read them immediately before promotion. An eligibility-epoch or
incompatible configuration mismatch aborts/restarts the builder; it never
publishes an authorization-old snapshot. A source high-water advance alone
does not discard an otherwise valid builder: promotion preserves that newer
range as durable dirty work for immediate catch-up.

Only a verified generation may be promoted. `Search.Projection`, the one writer
and serving-handle owner, serializes promotion with queries and incremental
writes. It stops new admissions, lets already-admitted reads finish within a
bound, and closes both builder and affected current handles before namespace
changes; a timeout leaves the current generation serving and aborts promotion.
Promotion uses same-filesystem rename only after
`PRAGMA wal_checkpoint(TRUNCATE)` returns `busy = 0` and a self-contained reopen
plus integrity/query check proves no required `-wal`/`-shm` sidecar. After the
fixed `current`/`previous` swap it opens and verifies the new current, publishes
that handle, and only then re-admits calls. Failure reopens the untouched or
retained previous verified generation and reports degraded state; no reader
keeps a renamed live SQLite handle and no pointer-service abstraction is added.

The Memory projection needs this identical sequence, so the checkpoint → close
→ self-contained reopen → integrity proof → atomic promote → retain-previous
steps live in one small shared private helper —
`AllbertAssist.Projection.PromoteProtocol`, owned by the Memory milestone and
consumed here after its contract rejoin — rather than being written twice
(v1.3 plan LD 62). Each domain keeps its own schema, verification predicates,
generation metadata, and rebuild source; only the promote sequence is shared.
Memory's first generation milestone owns the helper and its failure contract;
Search may implement its schema/parser work in parallel but rejoins on that
helper before its first promotion. The two real consumers use domain adapters;
the helper does not become a public or extensible projection framework.
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
the existing managed-job sync pattern over `scheduled_jobs` and
`scheduled_job_runs`. Its identities are the deterministic reserved job names
under the existing `(user_id, name)` unique constraint (the Repo already fixes
the Home); it uses exact-name lookups and never a bounded list or metadata scan.
Search Central owns exactly these three names:

1. `search-index`: bounded incremental ingest/reconcile, a coalesced dirty kick,
   and hourly repair;
2. `search-maintain`: weekly bounded prune/reconcile, incremental FTS merge,
   integrity check, and content-free health summary; and
3. `search-rebuild`: an **active** `manual`-schedule entry whose ordinary next
   due is `nil`, used on demand for resumable repair and generation changes. It
   is not represented as paused merely because it has no periodic due time.

Reconciliation creates an absent reserved name once. An occupied name without
the matching managed owner/spec, or a changed name, action, operation, or other
invariant, produces `managed_name_conflict`/visible degraded repair guidance;
it never overwrites an operator job, silently repairs an invariant, or creates
a duplicate managed identity. The sole upgrade adoption is an existing
`memory-index-rebuild` row whose exact legacy metadata has
`template_name: memory-index-rebuild` and
`managed_by: memory.review_cadence`, and whose local operator and target match
the known legacy template. Reconcile preserves its id, run history, allowed
cadence, and pause while atomically adding the new owner/spec metadata and
retargeting the compatible rebuild action. A template-only or otherwise
ambiguous row is a name conflict; this is not a generic adoption heuristic.
Normal Jobs updates reject mutation of those
managed invariants. The current Jobs interface has no generic delete operation,
so v1.3 adds no deletion API merely to forbid it. If a generic delete seam is
added later, it must reject positively identified managed rows while their
spec exists and direct the operator to feature disablement.

The durable job row is the authority for current allowed cadence and explicit
operator pause; Settings Central supplies feature enablement, defaults, and
bounds. Reconcile preserves an in-bounds operator cadence and pause instead of
resetting them to defaults. Feature disablement gates admission and clears an
effective due without erasing that operator intent, so re-enable cannot
silently unpause a row. Canonical conversation writes only mark Search's
durable source lag dirty and call `Jobs.Managed.kick/2` for `search-index`.
A kick atomically advances a content-free managed wakeup sequence and moves the
due time earlier only when the entry is active and feature-enabled. Paused or
disabled entries retain dirty lag without acquiring a due time.

Scheduler, manual, and dirty-trigger admission use one Jobs transaction, not a
check followed by insert. It verifies effective eligibility, creates the
`queued` run with its claimed due/wakeup sequence, and sets additive nullable
`scheduled_job_runs.admission_key` to the job id. A partial unique index over
non-null `admission_key` where status is `queued | running |
needs_confirmation` closes the race. Pre-migration rows remain null and are not
rewritten; the admission transaction still checks all legacy open rows before
insert, while every post-migration path supplies the key. A competing trigger
returns a typed coalesced/already-open outcome. Thus a manual run cannot overlap
a scheduler run, and a
queued or confirmation-blocked run is not mistaken for idle.

The domain action executes outside that short transaction. Completion then
atomically records the run result and reloads/merges the **current** job row; it
never calls due advancement on the stale pre-action struct. An explicit pause
or feature disable wins. Otherwise it consumes only the due/wakeup sequence the
run actually claimed, preserves any later kick, and chooses the earliest of the
next normal cadence, a later-kick due, and a bounded continuation due. A bounded
Search action reports `complete | incomplete` plus its durable domain cursor;
`incomplete` schedules that continuation in the completion merge rather than
self-kicking before stale due advancement. This is the required lost-wakeup
contract for every managed consumer, not Search-specific timer logic.

One Search feature setting — **`search.enabled`** — governs both query
availability and the ordinary local managed set, so "the feature is disabled" is
an unambiguous state and the purge precondition stays testable. Disabling stops
indexing and querying and leaves the projection on disk; removing bytes is the
separate confirmed purge. The operator
does not consent to each internal maintenance entry separately. Scope
expansions such as E2EE projection remain separately opted in.

That feature setting **defaults on for local Web, CLI, and TUI**, so a fresh
Home can search its own history without first discovering a switch. Mapped
operator DMs use the explicit `mapped_operator_dm` Search grant and E2EE
origins require the additional Search-specific overlay. This is
deliberately asymmetric with Memory's `memory.consolidation.enabled`, which
defaults false: Search is local, read-only, produces no proposals, injects
nothing into any prompt, and its entire database can be deleted and rebuilt,
whereas Memory collection derives durable new claims about the operator.
Indexing what the operator already wrote, for their own retrieval, is a
different act from concluding things about them. Both defaults are stated
together wherever either is documented. Managed rows stay visible when their
feature is disabled; no deletion tombstone is needed. Jobs are idempotent,
serialize the search writer, use bounded batches, expose
watermark/lag/generation/counts without content, and never hold the canonical
Repo and search writer in a claimed cross-database atomic transaction.

Bootstrap uses these same jobs. After managed-row reconciliation, an enabled
Search with no compatible verified generation—fresh Home, backup restore,
corruption recovery, or schema/tokenizer/redactor mismatch—kicks
`search-rebuild` unless the operator explicitly paused it. Queries return
`search_not_ready` with content-free phase/progress while it runs; `search-index`
does not open or mutate an unverified generation. Bounded rebuild work resumes
through the ordinary incomplete-continuation merge. Recoverable I/O failures
use the recurring engine's bounded backoff; a deterministic missing packaged
SQLite/FTS capability reports visible degraded capability instead of retrying
forever. Successful promotion kicks `search-index` to ingest writes beyond the
builder high-water. The hourly repair path also detects a missed bootstrap or
dirty kick without adding another process.

Weekly work uses bounded FTS merge steps rather than a routinely unbounded
`optimize`. Full optimization may occur only as measured manual rebuild
closeout.

### 8. Purge is separately confirmed and honestly best-effort

Ordinary reconciliation removes rows no longer eligible in the canonical
Corpus. Operator-requested purge uses the separately confirmed, registered
`purge_search_projection` action. It is `resumable?: true` and explicitly
allowlisted through the existing generic confirmation-resume path. Safe resume
parameters contain only target kind/ids or source classes, the expected
eligibility epoch, non-secret key ref/version, and an opaque
`allbert.search.purge-preview.v1` keyed preview binding over the exact managed
file/generation scope; they contain no query, message text, snippet, or plain
content digest. The affected canonical content must already be deleted/
ineligible, or the affected Search source class/feature must first be disabled;
the action rechecks this under current Corpus policy before every destructive
phase and otherwise returns a stale/precondition error because ingestion would
restore the text. Memory Forget remains ADR 0089's distinct action.

`AllbertAssist.Search.Control` owns one atomically replaced, content-free
`search-control.json` manifest under the Search root, outside every generation
database. It is the sole purge-recovery authority and records target ids/
classes, keyed preview binding, pending confirmation id, eligibility/policy
epoch, non-secret key ref/version, attempt metadata, and exactly one phase:
`pending | connections_closed | files_replaced | verified | complete`.
`last_error` and retry metadata are fields, not an `error` phase. It is neither
a deletion ledger nor a general transaction framework. Each phase transition
uses a same-directory temporary write, file sync, atomic rename, and parent-
directory sync before destructive work for that phase begins; the pending
confirmation id plus keyed preview identifies the one resumable attempt.

Entering `pending` durably advances the projection/policy epoch, invalidates all
cursors and resumable builders, and causes `Search.Projection` to quiesce new
calls and drain/close existing handles. While any non-`complete` phase exists,
queries and Search management operations other than continuation of that exact
purge return `search_purge_in_progress`; managed-job kicks may remain durable
for after completion but cannot reopen a database or erase operator pause.
Startup resumes the recorded idempotent phase and never promotes or opens a
pre-purge builder/generation.

Purge covers every Search-owned current, previous, build-temporary, failed,
retired, or pending-prune database plus its `-wal`/`-shm` sidecars. No openable
or startup-recoverable managed SQLite generation may retain the purged text.

For files that can be opened it combines FTS5 `secure-delete=1`, core
`PRAGMA secure_delete=ON`, `wal_checkpoint(TRUNCATE)` with `busy = 0`, and
`VACUUM` where the measured deletion path requires it and disk/lock
preconditions allow. Because enabling FTS secure-delete cannot remove older
tombstoned terms retroactively, any generation that may contain historical
deletes is replaced from the currently eligible canonical set; obsolete and
failed generations are deleted wholesale. The replacement is closed,
self-contained-reopened, integrity/query checked, and searched for the purged
fixtures before success. Each file/checkpoint/replacement/verification phase is
idempotent, and only a verified clean replacement may advance the manifest to
`complete`. Failure remains visible and does not produce a false “purged”
result. On completion, Search reopens only the verified replacement (or remains
not ready if none is eligible), then kicks `search-index` only when Search is
enabled and the operator has not paused that entry. This is best effort for
every Allbert-managed Search SQLite
file and sidecar in the confirmed scope; it does not promise erasure from
backups, snapshots, exported copies, filesystem remnants, or SSD wear leveling.

### 9. Search does not silently enter prompts or Memory

Ordinary search returns a result page to the requesting surface. It is never
automatically injected into Runtime prompts, Active Memory, consolidation, or
model context. An explicit operator summarize action may submit a selected,
re-authorized result set to the model for that response only. It creates no
Memory proposal and no Search-to-Memory promotion path exists.

Search control/authorization/operational state, Security confirmation/resume
state, Search action requested/completed/error signals, validation diagnostics,
action logs, and Jobs target/run summaries do not store query text, MATCH
syntax, snippets, result message text, plain query/filter digests, or filter
operand values. Trace-safe metadata may record query/chain id, verified
principal/surface, policy scope class, generation/revision, ordering mode,
filter kinds/count, result/filtered counts, duration band, confirmation outcome,
and error class.

This redaction occurs before observability, not inside the Search action after
Runner has already emitted input. The registered action supplies a trace-safe
parameter/result projection that `Actions.Runner` invokes before
`action_requested`, validation-error, and `action_completed` signals. Callback
failure omits action parameters/results rather than falling back to raw values.
The same projection governs action logs, Jobs run summaries, and confirmation
summaries/resume references. The one-query DM approval stores only the resolved
confirmation id, keyed binding, and safe source/scope metadata defined in §5;
raw query text is transiently resubmitted after approval and never becomes
durable confirmation state.

This is intentionally a Search-owned-state claim, not a global retention
promise. An operator's query is an ordinary canonical conversation message and
may later enter the projection as ordinary eligible history; a deterministically
rendered result may be an ordinary assistant message; and configured providers
or general turn traces may retain their normal copies under existing policy.
There is no additional Search-specific query log, and Search purge does not
erase or permanently suppress those ordinary copies. The typed Search-result
marker from §3 prevents a rendered result from re-entering the Search
projection, but does not pretend the canonical/provider turn vanished.

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
- Exact managed names and one atomic Jobs admission/completion seam make
  recurring work visible and operator-controllable without a second job model.
- Purge quiescence makes the best-effort file claim testable without expanding
  it into canonical/provider/backup erasure.

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
- No Search-specific query-grant store, deletion ledger, generation-pointer
  service, private wakeup process, or generic Jobs delete API.

## Validation

Acceptance combines focused contract/race tests with proof against the native
SQLite library loaded by each packaged target:

- the Exqlite-loaded library—not a host `sqlite3`—reports
  `sqlite_version() >= 3.42.0` and functionally proves FTS5 create/insert/term/
  phrase/prefix/BM25/snippet with `unicode61 remove_diacritics 2`, rank ties,
  WAL, `PRAGMA integrity_check`, FTS integrity, `secure_delete`, FTS
  `secure-delete=1`, checkpoint-TRUNCATE `busy = 0`, partial unique indexes,
  and locator/FTS shared-rowid bijection;
- duplicate source ingestion updates exactly one locator/FTS pair; lookup,
  typed filters, timestamp ordering, and delete use the ordinary locator and its
  frozen B-tree indexes rather than scanning FTS; integrity rejects duplicate,
  missing, or mismatched rowid pairs;
- index eligibility and immediate query-time drop cover canonical deletion,
  digest drift, identity remap, visibility/grant change, legacy-unverified
  assistant origin, hidden/tool/system/secret/action-log rows, and E2EE denial.
  Exact mapped-DM origin tuple plus canonical-thread equality prevents a merged
  thread from widening scope, and a typed Search-result turn never re-enters the
  projection;
- relevance/newest/oldest ties, generation/revision/request/scope binding,
  bounded post-authorization refill with stale leading candidates,
  last-scanned cursor position, incomplete scan-budget outcome, stale-cursor
  restart, and no canonical scan fallback are deterministic across surfaces;
- local Web/TUI/CLI parity, one mapped-DM consumer grant without per-channel
  prompts, exact-origin same-DM default, E2EE disclosure/opt-in, and one-query
  cross-surface elevation prove the allowlisted generic resume of
  `authorize_search_query_scope`, `query_resubmit_required`, resolved
  `confirmation_id` chain, changed-source/request/expiry rejection, pagination
  without reprompt, and absence of any second grant store;
- Search requested/completed/error/validation paths, confirmation/resume state,
  action logs, and Jobs target/run summaries contain only the safe projection.
  The same fixtures explicitly acknowledge the ordinary canonical query/result
  turns and configured provider/general-trace retention rather than asserting a
  false global no-query guarantee;
- rebuild/repair proves independent source high-water and eligibility epoch,
  post-high-water write survival, incompatible-epoch/config builder rejection,
  one-writer serving-handle quiescence, `busy = 0` checkpoint/close/self-
  contained reopen/swap, no renamed live handle, failed-generation
  non-promotion, and previous-generation recovery;
- fresh Home, authoritative-backup restore, corrupt/missing generation, and
  schema/tokenizer/redactor mismatch bootstrap through the visible active/manual
  `search-rebuild` row; explicit pause is preserved, recoverable failure backs
  off, deterministic capability failure degrades, and successful rebuild kicks
  post-high-water catch-up;
- deterministic `search-index`, `search-maintain`, and `search-rebuild` names use
  exact lookup; collision/invariant mutation degrades without overwrite or
  duplicate; allowed cadence/pause survives reconcile/disable; and no generic
  Jobs delete API is introduced. Scheduler/manual/dirty races admit one open
  `queued | running | needs_confirmation` run, and completion tests prove a
  later kick, pause, cadence edit, and `incomplete` continuation cannot be lost
  to stale due advancement;
- canonical message/thread deletion proves generic confirmation resume, exact
  transaction-time cascade recheck under concurrent append/reference mutation,
  post-commit `already_deleted` retry, fresh `not_found`, message
  `last_message_at` recomputation, retained-title disclosure, live-dependency
  blocking, surviving separately governed provenance, Memory staling, and
  idempotent Search dirty repair;
- `purge_search_projection` proves allowlisted resume and target/precondition
  rebinding, atomic control-manifest phases, quiescence and
  `search_purge_in_progress`, restart after each phase, historical-delete
  replacement, negative fixture checks across every Search-owned generation/
  database/sidecar, and conditional post-completion catch-up without claiming
  backup/filesystem/hardware erasure; and
- ordinary Search remains isolated from model/Memory except for the separately
  explicit summarize-only path.

Primary SQLite evidence: [FTS5](https://www.sqlite.org/fts5.html),
[external-content constraints](https://www.sqlite.org/fts5.html#external_content_tables),
[`CREATE INDEX` limits on virtual tables](https://www.sqlite.org/vtab.html),
[partial indexes](https://www.sqlite.org/partialindex.html),
[`unicode61`](https://www.sqlite.org/fts5.html#unicode61_tokenizer),
[BM25](https://www.sqlite.org/fts5.html#the_bm25_function),
[WAL](https://www.sqlite.org/wal.html),
[FTS secure-delete](https://www.sqlite.org/fts5.html#the_secure_delete_configuration_option),
[core secure-delete](https://www.sqlite.org/pragma.html#pragma_secure_delete),
[WAL checkpoint](https://www.sqlite.org/pragma.html#pragma_wal_checkpoint), and
[`VACUUM`](https://www.sqlite.org/lang_vacuum.html). Same-filesystem rename
semantics come from
[POSIX `rename`](https://pubs.opengroup.org/onlinepubs/9799919799/functions/rename.html).
