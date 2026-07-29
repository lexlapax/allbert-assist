# ADR 0093: Canonical Conversation Deletion And Retention Boundary

## Status

Proposed (v1.3, operator-signed final readiness decision 2026-07-28). Binding on
the Corpus milestone (M2) in the v1.3 plan; flips Accepted when the confirmed
delete action, its exact conversation-owned cascade, live-dependency blocking,
survivor disclosure, crash-safe idempotency, and cross-consumer reconciliation
rows are green.

M2's canonical action/cascade/confirmation rows are green as of 2026-07-29 at
`ffbe8fda`. This ADR remains Proposed until the M4/M6/M7 consumers exist and the
M8 cross-consumer deletion/proposal/projection rows pass; implementation order
does not weaken the decision's acceptance bar.

This ADR extracts the canonical-deletion decision that the fifth readiness pass
found specified inside ADR 0092 §3. Deleting the operator's conversation history
is a destructive capability over canonical user data with its own consent,
cascade, and disclosure contract; it is not a Search concern, and it is built by
the Corpus workstream, not the Search workstream. Search consumes deletion as an
input to reconciliation and owns none of it.

Related: ADR 0002 (canonical records versus projections), ADR 0006 (Security
Central and destructive confirmation), ADR 0057 (cross-channel conversation
threading — the thread/channel identity this cascade walks), ADR 0089 (Memory
claims survive source deletion; Forget is a different action), ADR 0092 (Search
consumes deletion as a reconciliation input), and ADR 0040 (confirmation
contracts).

## Context

Conversation threads and messages are canonical SQLite rows. Before v1.3 there
was no operator-facing way to delete any of it: retention was indefinite and
unconditional. Three v1.3 capabilities make that gap untenable.

Search Central makes every retained message findable by full-text query, so
history the operator assumed was effectively buried becomes immediately
retrievable. Memory Forget removes what Allbert *concluded* from a statement but
deliberately leaves the statement itself, so without canonical deletion an
operator who forgets a fact can still search up the message that stated it.
And the Corpus boundary now hands conversation content to two independent
consumers, so "delete this" needs one authority that both must honor rather than
two consumers each pruning their own projection.

The hazard is over-claiming. Conversation rows are referenced by objectives,
jobs and runs, channel events and deliveries, artifacts, traces, workspace
state, StockSage records, and potentially by plugin data Allbert does not
enumerate. A deletion that silently cascaded into all of them would destroy
separately governed records; one that claimed to have deleted "everything"
would be lying. The design therefore deletes a narrow, exactly-previewed set and
*discloses* what survives.

## Decision

### 1. One registered, destructively confirmed action

`delete_conversation_content` accepts schema-1 `%{target_kind: :message |
:thread, target_id: String.t(), expected_digest: nil | "sha256:" <>
lower_hex_64}`. The
target must belong to the verified canonical user/operator. It is
`resumable?: true` and explicitly allowlisted through the existing generic
confirmation-resume path; its stored resume parameters carry only the verified
user/operator id, target kind/id, non-secret key reference/version, and the
opaque server preview binding — never message content or plain content digests.
Approval compares that stored server-derived user id with the current
authenticated user before entering the Repo transaction.

There is exactly one such action. Surfaces render and dispatch it; none
implements its own deletion path.

### 2. The preview is bound, and approval re-resolves it

The preview DTO is `%{schema_version: 1, target_kind, target_id, message_count,
reference_count, blocker_counts, survivor_counts, retained_thread_title?:
boolean, disclosure_version: 1, preview_binding}`, where `preview_binding` is
`"hmac-sha256:" <> lower_hex_64`. Closed non-negative-
integer `blocker_counts` keys are `active_jobs`, `active_objectives`,
`nonterminal_fanout_deliveries`, and `open_workspace_states`; closed
`survivor_counts` keys are `historical_jobs`, `historical_runs`,
`historical_objectives`, `stocksage_rows`, `channel_events`,
`channel_deliveries`, `artifact_links`, `traces`, and
`closed_workspace_states`. Unknown plugin copies are disclosed as uncounted,
never represented by a false zero. The content-free result DTO
is `%{schema_version: 1, target_kind, target_id, outcome: :deleted |
:already_deleted, deleted_message_count, deleted_reference_count,
retained_thread_title?: boolean, downstream_reconcile_required: boolean,
disclosure_version: 1}`. Typed pre-commit errors are `:not_found | :stale |
:live_dependency | :unauthorized`; safe blocker detail appears only for
`:live_dependency`.

The server preview binds `allbert.conversations.delete-preview.v1` over the
user/operator id plus either the message id/version/content digest, or the
thread id/version plus the stable ordered exact conversation-owned cascade of
message and channel/message-reference row identities, versions, and content
digests — followed by a versioned ordered known-core survivor/blocker count
vector and the disclosure version. A caller may supply an optional expected
digest, but resolved confirmation state retains no plain content-derived hash.

For the current additive schema, a message row version is immutable
`inserted_at` plus content digest; thread/channel/message-reference row versions
are `updated_at` plus their safe identity fields. M2 does not add a generic row-
version column merely for this action.

The optional caller precondition has one closed interpretation: a message
digest is SHA-256 of exact content, while a thread digest is SHA-256 of the
NUL-joined canonical-order sequence of per-message `sha256:` content digests.
It is only an early stale check; the server HMAC remains the approval authority.

Approval recomputes that complete cascade and bound count/disclosure vector
inside the immediate canonical Repo transaction. A concurrent append,
reference, or known-core dependency change makes the confirmation **stale**
rather than expanding its authority. Confirmation approves an exact set, not a
predicate that may match more rows later.

### 3. The cascade is conversation-owned and nothing else

Message deletion removes the one message and its conversation-owned message
references. Thread deletion uses only the existing conversation thread/message/
channel-reference cascade and removes the canonical thread row and its title.

Message deletion recomputes `conversation_threads.last_message_at` from
surviving messages, using `MAX(conversation_messages.inserted_at)` and falling
back to the thread's own `inserted_at` when none survive. A thread title
previously derived from the deleted message is **retained and disclosed**,
because the current schema has no title-provenance field and v1.3 does not
invent one merely to guess whether the operator renamed it.

### 4. Live dependencies block; historical records survive and are disclosed

Before thread deletion, a best-effort known-schema inventory blocks on live
execution-bearing references — active origin-thread jobs or objectives,
nonterminal fan-out delivery, open workspace state — and returns finish,
cancel, or rehome guidance. Approval rechecks those blockers inside the same
immediate Repo transaction as the cascade.

Historical jobs and runs, objectives, StockSage rows, channel events and
deliveries, artifacts, traces, and closed workspace state remain separately
governed records whose readers show unavailable-source provenance. Unknown
plugin copies are **disclosed** rather than covered by a false universal-cascade
claim. The inventory is explicitly best-effort over known core schemas.

The disclosure names, before confirmation, what deletion does not reach:
separately kept Memory claims, provider and server copies, exports, backups,
snapshots, traces, filesystem remnants, and — for a message target — a retained
thread title.

### 5. Crash safety without a new ledger

The durable pending confirmation id and its bound preview are the idempotency
key. If the Repo commit succeeds but confirmation resolution does not, retrying
that same pending approval finds the target absent, returns `already_deleted`,
and re-drives idempotent Memory-stale and Search-dirty reconciliation. A fresh
request for an absent target returns `not_found`. No cross-store transaction,
action-receipt row, or deletion-ledger table is added.

### 6. Consumers reconcile; they do not decide

Deletion commits canonically first. Corpus then reports the source missing or
ineligible immediately, so query-time and review-time reauthorization cover the
whole interval before physical projection repair. The action marks Search dirty
for ordinary reconciliation and returns only safe target/outcome/count metadata.

Pending Memory proposals and legacy drafts whose only provenance is the deleted
source become content-free stale outcomes. Separately kept Memory claims are
**not** deleted: they remain governed by Archive and Forget (ADR 0089), and
their provenance reports the source as unavailable. Deleting history is not an
implicit revocation of a decision the operator separately made.

### 7. Retention itself is unchanged

Canonical conversations are retained indefinitely until an explicit confirmed
deletion. v1.3 adds no automatic retention window, no age-based pruning, and no
policy engine. Search maintenance prunes stale projection rows and obsolete
generations only; that is never canonical deletion.

## Consequences

- The operator gains a real, bounded way to remove conversation history, which
  Search Central otherwise makes permanently and instantly discoverable.
- Memory Forget and canonical deletion become a coherent pair: Forget removes
  what Allbert concluded, deletion removes what was said, and each disclosure
  names the other as the further step.
- Deletion has one authority both consumers honor, rather than each projection
  pruning independently.
- The survivor disclosure is the honest cost: Allbert states plainly that
  separately governed records and copies outside its active store remain.
- No retention policy, cascade framework, or deletion ledger enters the system.

## Non-goals and guardrails

- No automatic or age-based conversation retention, pruning, or expiry.
- No universal cascade claim across plugin or non-core data; the inventory is
  best-effort over known core schemas and says so.
- No deletion of separately kept Memory claims, and no implicit Forget.
- No cross-store transaction, action-receipt row, or deletion-ledger table.
- No claim of erasure from provider/server copies, backups, snapshots, exports,
  filesystem remnants, or storage hardware.
- No second deletion entry point; surfaces dispatch the one registered action.
- No title-provenance field invented to guess whether a thread title came from
  the deleted message.

## Validation

Gate-bound rows (v1.3 request flow §J and plan M2):

- a preview whose cascade or known-core count vector changes before approval
  fails **stale** rather than deleting a widened set;
- message deletion recomputes thread recency correctly with and without
  survivors, and retains plus discloses a derived title;
- thread deletion blocks on live jobs/objectives/fan-out/workspace state and
  rechecks those blockers inside the deletion transaction;
- a crash after canonical commit but before confirmation resolution replays to
  `already_deleted` and re-drives reconciliation, while a fresh absent request
  returns `not_found`;
- deletion makes the source ineligible at Corpus immediately, so an unrepaired
  Search projection cannot disclose it and pending Memory proposals go stale;
- an independently kept Memory claim survives with unavailable-source
  provenance until Archive or Forget;
- the confirmation disclosure enumerates the surviving separately governed
  records and the copies outside the active store.
