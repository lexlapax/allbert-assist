# Conversation Search

Allbert Search Central finds messages in canonical conversation history. It is
one local API used by Web, TUI, the packaged CLI, and verified mapped operator
DMs. Those surfaces parse and render requests; they do not own indexes, ranking,
scope, or deletion behavior.

Conversation Search is different from `allbert admin memory search`. Search
Central searches retained conversation messages and never inserts results into
model prompts. Memory search reads reviewed claims that can be admitted to
Active Memory. Neither consumer reads the other's projection.

## Search From A Local Surface

Local Web, TUI, and CLI requests search all currently eligible history by
default:

```sh
allbert search -- "release validation"
allbert search --order newest --limit 10 -- "release validation"
allbert search --order oldest --author user -- '"exact phrase"'
allbert search --surface tui --thread THREAD_ID -- "provider doctor"
```

In Web or TUI, use the same closed grammar as a slash command:

```text
/search release validation
/search --order newest --limit 10 -- release validation
```

When options are present, `--` is required before the query. Supported options
are:

- `--order relevance|newest|oldest`
- `--limit N` (default 20, maximum 100)
- repeatable `--author`, `--surface`, and `--thread`
- `--after ISO8601` and `--before ISO8601`
- `--e2ee`
- `--cursor CURSOR` for the next page

Results contain a redacted snippet, author, source surface, timestamp, trust
class, canonical message id, and canonical thread id. `Next cursor` is bound to
the exact request, authorization scope, generation, and projection revision. If
Search reports `search_changed`, restart at page one; do not reuse a cursor from
an older index revision.

Search is lexical: words, one bounded quoted phrase, and explicit prefix terms
are supported. There is no fuzzy, substring, semantic, or embedding fallback.
Search never silently truncates an invalid or oversized query into a different
one.

## Mapped Operator DMs

A verified mapped one-to-one operator DM searches only its canonical thread and
exact current channel origin by default. Shared conversations and unknown
one-to-one classifications are excluded. Merged-thread membership does not widen
the scope.

Mapped-DM use is opt-in once per Home:

```sh
allbert admin settings set search.origin_grants local_operator,mapped_operator_dm
```

Use `--all-history` only for one deliberate cross-surface request. Allbert
creates a content-free confirmation instead of storing or replaying the query:

```text
/search --all-history -- release validation
```

Approve the returned id through the ordinary confirmation surface, then
resubmit the exact query within five minutes with `--chain CONFIRMATION_ID`.
Changing the query, filters, order, limit, principal, or origin requires a new
confirmation. Pagination may reuse the chain only until its original expiry.

E2EE-origin indexing is a separate opt-in because the local FTS projection is a
redacted but plaintext-derived file:

```sh
allbert admin settings set search.origin_grants local_operator,mapped_operator_dm,e2ee_operator
```

There is no additional encryption layer. Protection comes from local filesystem
permissions, canonical authorization on every result, backup exclusion, and the
explicit purge path.

## Index Health And Recurring Work

Search is enabled for local operator surfaces by default. Its SQLite FTS
projection is disposable and lives below
`<ALLBERT_HOME>/projections/search/`. The packaged Exqlite runtime—not a host
`sqlite3` command—must supply the required SQLite and FTS5 capabilities.

The existing recurring Jobs engine owns all Search background work:

| Managed job | Purpose |
|---|---|
| `search-index` | Coalesced ingestion and hourly repair. |
| `search-maintain` | Weekly integrity checks and bounded generation pruning. |
| `search-rebuild` | Manual/recovery rebuild with resumable bounded pages. |

Inspect the ordinary Jobs rows and histories:

```sh
allbert admin jobs list --user local
allbert admin jobs show JOB_ID
allbert admin jobs runs JOB_ID --limit 20
allbert admin jobs run JOB_ID
allbert admin jobs pause JOB_ID
allbert admin jobs resume JOB_ID
```

Pausing a managed job preserves the operator's pause, cadence, and any dirty
work that arrives while paused. `allbert admin jobs show JOB_ID` reports
`Next due: none` until resume; resume computes one catch-up opportunity and the
ordinary atomic admission rule still permits at most one open run. This is the
same central managed-job rule for Memory and Search identities. Disabling
Search retains its rows and dirty intent but also keeps their effective due time
empty and blocks admission:

This exact nil-due invariant is the v1.3.1 source correction. The v1.3.0
packaged scheduler still blocks paused work, but a dirty kick can repopulate its
displayed due timestamp. Installed operators receive the corrected state in
v1.4.0; source validation uses the same commands through `mix allbert admin jobs
…` against the source daemon.

```sh
allbert admin settings set search.enabled false
allbert admin settings set search.enabled true
```

A missing or incompatible generation triggers the managed rebuild path. Search
returns a typed not-ready/degraded response and never scans canonical tables as
a fallback. A healthy result reports index freshness; the normal freshness SLO
is 90 seconds after an eligible canonical change.

## Retention, Delete, And Purge

Pruning or rebuilding Search changes only its disposable projection. It does
not delete canonical conversation history. Canonical deletion is separately
confirmed and commits before Search reconciliation:

```sh
allbert admin threads delete-message MESSAGE_ID --user local
allbert admin threads delete-thread THREAD_ID --user local
allbert admin confirmations approve CONFIRMATION_ID --reason "remove exact canonical content"
```

The preview reports exact canonical message/reference counts and retained
record classes without echoing message content. Thread deletion refuses live
dependent work. Deleting a Memory claim is not a substitute: Memory Forget
deliberately leaves the originating conversation retained and searchable.

Search's separately confirmed secure purge is for projection cleanup after the
canonical source is already deleted/ineligible or the relevant Search source
class is disabled. It does not claim erasure from backups, snapshots,
filesystem remnants, provider/server copies, or unknown plugin copies.

## Privacy And Troubleshooting

- Search query text, snippets, filter operands, and plain query digests are not
  written to Search-owned traces, managed-job state, or confirmations.
- Canonical conversation retention remains independent; an ordinary chat turn
  that asks for Search still follows conversation retention policy.
- Search-rendered assistant turns carry an exclusion marker so snippets do not
  recursively enter the index.
- Canonical reauthorization happens before every result is returned. A stale,
  deleted, remapped, or newly ineligible projected row is omitted and repair is
  queued.
- Authoritative Home export/backup omits Search and Memory projection files.
  Restore rebuilds them from canonical conversation and Markdown claim data.

For Memory review, temporal lookup, archive/restore, and Forget, see
[Active Memory](active-memory.md). For the exact architecture and retention
boundary, see ADR 0092 and ADR 0093 in the [ADR index](../adr/README.md).
