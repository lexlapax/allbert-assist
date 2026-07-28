# ADR 0002: Markdown-First Memory

## Status

Accepted.

## Context

Allbert should become more personal over time while keeping the user in control
of what it remembers. The origin note calls for memory that can be stored in
markdown files for posterity and transfer, with compiled runtime views for
performance. The vision keeps the same posture: user-owned knowledge should
remain readable, portable, and inspectable.

Storing memory only in an opaque database or vector index would make early
development faster in some ways, but it would weaken the core product promise:
the assistant should grow with the user without making its memory hard to
understand or move.

## Decision

Markdown files are the source of truth for Allbert memory. v0.01 will store
notes, preferences, traces, skill records, and recent memory entries as
human-readable markdown. Runtime indexes, embeddings, summaries, and other
compiled views may be added later, but they are derived artifacts rather than
the primary memory record.

## Consequences

- Users and developers can inspect and edit early memory without special tools.
- Memory content can be transferred by moving files; Home-key-bound v1.3
  authority is re-confirmed at the destination as described below.
- Early retrieval should stay simple: recent entries, selected files, and
  summaries before embeddings or vector search.
- Future indexing work must preserve markdown as the durable source of truth.

## Amendment (v1.3 readiness, 2026-07-28) — authorities and projections

The markdown-first rule applies specifically to **Memory**. Long-term-memory
claim streams remain human-readable markdown and are the canonical Memory
record. Their compiled candidate/index projection is disposable and rebuildable;
it cannot create, revise, retire, or forget a claim.

Every authority-bearing transition created after v1.3 ships is both digest-
chained and authenticated. The transition records its non-secret key reference
and version and carries an HMAC-SHA-256 tag over a versioned, unambiguous
encoding of the claim id, revision id and sequence, previous-revision digest,
canonical transition payload digest, deterministic transition id, and typed
actor/action provenance. The domains
`allbert.memory.claim-transition.v1`,
`allbert.memory.manual-confirmation.v1`,
`allbert.memory.destination-chain-confirmation.v1`, and
`allbert.memory.forget-suppression.v1` are distinct. Hash chaining detects
mutation; the tag is what distinguishes a registered-action transition from
text fabricated in an editable file. No Repo receipt or projection row becomes
a second authority.

The shared system-integrity helper established by ADR 0091 derives
`domain_key = HMAC-SHA256(home_integrity_key, UTF8(domain_string))`, then
computes the record tag as HMAC-SHA-256 of the domain key and canonical
length-prefixed payload. No consumer uses the raw Home key directly or invents
its own encoding.

The only supported raw manual change shape is a new append-only revision. A raw
filesystem append has no native-transition tag and is quarantined until the
operator reviews and confirms that exact revision through the registered one-
claim repair/import action. Confirmation appends a content-free
`manual_import_confirmed` transition that binds the unchanged pending revision,
whole prior-chain digest, and normalizer version using the manual-confirmation
domain. Projection rebuild admits the manual revision only
when that locally verifiable confirmation follows it with no intervening
content revision. Modifying, removing, or reordering an earlier revision,
inventing a native transition, or presenting a missing/invalid tag quarantines
the claim. File contents alone never grant authority.

One 32-byte random per-Home integrity secret is auto-provisioned through the
existing Settings Secrets/Key Custody implementation at the additive shared
fixed reference `secret://system/integrity_v1` (record version `1`) before the
first post-v1.3 Memory write. The TUI receipt milestone introduces that system-
owned namespace and key; Memory asks its helper to apply only the four fixed
domains above and never receives raw material. One
serialized system-secret `fetch_or_create` operation on the existing Key Custody
process durably stores the secret before returning it, so concurrent first
writes receive the same material and a claim can never commit first. A genuinely
fresh Home with no durable TUI/Memory/Search/delete-preview reference may create
it. A Home that already contains any domain reference must never generate
replacement material under the same reference/version: affected native streams
quarantine, new claim writes fail with `memory_integrity_key_unavailable`, and an unverifiable Forget
tombstone keeps proposal production fail-closed. Automatic material rotation is
out of scope. Settings master-key changes rewrap the same secret, and an old
integrity-key version cannot be removed while any receipt, claim, confirmation,
tombstone, cursor/control record, or delete preview still references it. This is
one small extension of Key Custody, not a new key service.

Pre-v1.3 flat entries retain their exact existing meaning as a grandfathered
synthetic revision zero; there is no bulk rewrite or retroactive tag. Their
synthetic claim id is UUIDv5 in namespace
`3a933b90-6d58-5d8c-9cdb-1233c996532f`, using name bytes
`legacy-memory-v1\0<category>\0<relative-path>`. The relative path is lexical
under the resolved Memory root, uses `/` separators and Unicode NFC, collapses
`.`/`..`, and preserves case; a path that escapes the root is invalid. The
derivation never reads or hashes the claim body or normalized value. Before
lazy adoption, a rename is therefore a remove plus a newly discovered legacy
entry; after the first native transition embeds the claim id, later moves
preserve identity. The first lifecycle mutation appends the requested signed
native transition with a `legacy_adopted` envelope binding the synthetic id and
complete legacy-file digest. Two files that declare the same embedded claim id,
or an otherwise impossible synthetic-id collision, quarantine both instead of
choosing a winner. A copied forgotten value remains denied by the keyed
suppression token even if its pre-adoption path, and therefore its synthetic id,
changes.

All supported writes converge on one per-claim serialized compare-and-append
interface:
`Memory.Claims.append(claim_id, expected_tail_digest, transition)`. Under the claim lock it
rereads and validates the complete stream, rejects a stale expected tail,
rechecks pending/completed tombstones immediately before commit, and recognizes
an identical deterministic transition as an idempotent retry. It writes the
complete replacement to a same-directory temporary file, syncs the file,
atomically renames it, then syncs the parent directory before releasing the
lock. Replacements preserve the existing file mode; new streams use the private
Memory-file default. A detected concurrent raw edit fails closed and preserves
the operator's file; abandoned temporary files are never parsed as claims and
are cleaned by bounded repair.

Markdown content remains portable, but a Home-bound integrity tag is not
portable authority. A same-Home restore with the original Key Custody secret
verifies normally. At a destination Home without that secret, structurally
valid imported streams remain readable but quarantined. One registered action
may explicitly confirm the exact unchanged whole-chain digest under the
destination key and append a content-free `destination_chain_confirmed`
transition under the destination-chain-confirmation domain; it never rewrites
or pretends to verify the source Home's tags. Any
content or chain change requires a new preview and confirmation. Allbert does
not export keys or add a cross-Home key-management subsystem.

Conversation history has a different authority:
`AllbertAssist.Conversations.Corpus` is the canonical, policy-filtered
conversation read boundary over the durable conversation store. It is not a
second Memory source of truth. Search Central's SQLite FTS database and Memory's
compiled projection are separate derived stores, each rebuildable only from its
own canonical authority. Search results never become Memory merely because they
were found or summarized; ADR 0089 owns Memory collection and review, while ADR
0092 owns search.
