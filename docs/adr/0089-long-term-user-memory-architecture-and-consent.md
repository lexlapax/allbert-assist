# ADR 0089: Long-Term User Memory Architecture And Consent Boundary

## Status

Accepted (v1.3 M9.b.1, 2026-07-30; operator-signed architecture and consent
boundary). The architecture choices formerly named LD-R1–R5 are resolved by
§8, ADR 0092, and the archived v1.3 plan. M1 froze fixtures, quality floors,
budgets, and runtime evidence without reopening source, proposal,
extraction-authority, retrieval, model-egress, temporal, or Search ownership
decisions. M4 implemented grounded proposal/review authority, and M5 proved the
binding source-tree chain — system proposal → proposed-never-in-prompt denial →
operator Keep → prompt-time retrieval — plus reviewed supersession with the
prior value absent from current context and both revisions auditable on disk.
The v1.3 plan's M5 Build Progress records frozen extraction/abstention and
10,000-claim latency evidence. M9.b.1 adds the separately required synthetic
seeded-fact evaluator and records a configured `local_ollama/llama3.2:3b` run:
6/6 reviewed facts answered, 3/3 absent/proposed/superseded rows abstained,
zero-shot uplift `1.0`, and complete compact-versus-source token/interaction
metrics. Together with the M5 full chain and supersession cycle, that closes the
Accepted flip below. Final packaged latency and release gates validate the
release candidate but no longer leave this architectural decision Proposed.

**Clarified 2026-08-05 (v1.3.1 corrective hardening, operator-signed).** The
derived generation watermark is explicitly the input digest of the last full
build, not a live cursor advanced by incremental refresh. v1.3.1 renames it
`full_build_source_watermark` and rebuilds schema-1 disposable projections.
Incremental truth remains `projection_revision`, per-claim revision digests,
and canonical reauthorization. This avoids an O(n) claim-stream scan and a new
global writer lock on every one-claim refresh; no canonical Memory authority or
public contract changes.

**Amended 2026-07-28 (implementation-readiness pass, operator-signed).**
The pass surveyed the deployed long-term-memory literature and found the
original decision modelled memory as append-only: it handled restatement
(idempotent dedupe) but not contradiction. §7 below adds the bi-temporal
fact lifecycle in response; §2 extends the consent boundary to cover
unmaking a fact; §3 restricts what may originate a fact; §5 adds
abstention to the measured claim; §6 gains FTS decision criteria. LD-R3
is subsumed by §7 and retained only as pruning UX. At this intermediate pass,
LD-R1/R2/R4/R5 still awaited disposition; the second readiness amendment below
resolves them and makes M1 calibration-only.

**Amended 2026-07-28 (second implementation-readiness pass,
operator-signed).** §8 below binds collection eligibility to a verified
principal rather than a message role, separates Memory collection policy from
Search policy, replaces mutable/newest-recorded-wins lifecycle language with an
append-only valid-time/known-time claim stream, and defines the exceptional
confirmed Forget path. It supersedes §1's broad episodic-source list, the
conflicting collection/proposal rules in §§2–3, and §6's
conditional/external-content design: ADR 0092 now owns Search Central, and
there is no Search-to-Memory bridge.

**Amended 2026-07-28 (third implementation-readiness pass, operator-signed).**
A code-level cross-check added §9 (legacy memory subsystems are absorbed rather
than shipped beside the new model, behaviorally and without deleting public
shapes), span provenance as the enforceable form of the assistant-authority
rule in §8, and the retained-searchable-conversation clause in the Forget
disclosure. It also recorded that the confirmed canonical conversation delete
action required by the plan does not yet exist and is built in M2.

**Amended 2026-07-28 (final implementation-readiness pass,
operator-signed).** The final cross-document audit makes the consent grant
origin-scoped, narrows span grounding to consolidation-produced conversation
proposals, binds review and Forget to restart-safe idempotent protocols, and
states the physical SQLite-deletion limit honestly. It also freezes destination-
Home re-confirmation, authenticated native transitions, serialized claim
compare-and-append, durable per-message principal evidence, ordered startup
repair, content-free legacy-draft drainage through the one claim writer, stable
legacy identity, and bounded canonical re-authorization of projection
candidates. These are implementation contracts, not new subsystems.

This is the **first ADR-level memory contract**: the v0.39b Active Memory
baseline is bound today only by a research note
(`docs/research/active-memory-retrieval.md`) and an archived plan.

Related: ADR 0002 (markdown-first memory — files remain source of truth),
ADR 0005 (Allbert Home layout), ADR 0014/0021/0039/0040 (the four
"no automatic memory promotion" non-goal anchors — this ADR keeps the
review line and defines the sanctioned proposal path those non-goals
anticipated), ADR 0045 (operator-supervised self-improvement — the draft
trust tier the consolidation pipeline parallels), ADR 0061 (local
embedding — routing-only; retrieval here stays lexical), ADR 0083/0084/0085
(the v1.1 background-work substrate consolidation jobs ride), ADR 0031/0006
(Settings/Security Central), ADR 0093 (canonical conversation deletion — the
paired act that removes what was said, where Forget removes what Allbert
concluded), and ADR 0090 (adaptive usage profiling — the
system-facing sibling that consumes the same usage-history sources in
v1.8).

## Context

The stated goal, from the backlog entry this ADR consumed (since removed from
future-features.md): a long-term user
memory that remembers facts about the operator's life and preferences,
**periodically consolidated by the system from interaction history** — not
only explicit "remember this" asks — consulted at prompt-formation time so
answers land zero-shot, cutting token usage and interaction count.

What exists (verified 2026-07-24, anchors in the v1.3 plan):

- **Active Memory (v0.39b)** — deterministic, lexical, recency-weighted
  retrieval over reviewed `:kept` entries only
  (`memory/active_memory.ex`), scoped `{thread_id, active_app,
  identity_namespace}`, injected **only** into the direct-answer/vision
  prompt (`req_llm_answerer.ex:124`, 8,000-byte budget). Review statuses:
  `:unreviewed | :kept | :flagged | :prune_nominated` (`entry.ex:29`).
- **Write paths** — explicit "remember" intents (`append_memory`),
  conversation-turn promotion, app/system upserts, and the v0.47
  operator-supervised draft pipeline (kinds `memory_promotion` /
  `memory_update` through `Drafts.Store` → confirmation-gated promote
  actions) — on-demand only; nothing periodic exists.
- **Usage history** — conversations (`conversation_threads/messages` with
  `action_log` and trace links), the markdown trace corpus (indexable via
  `SelfImprovement.TraceIndex`), objectives/events, jobs runs. Unbounded,
  unsearched (no FTS), never pruned automatically.
- **Jobs substrate** — durable scheduled jobs targeting `runtime_prompt`
  or `registered_action`, with the settings-driven managed-job precedent
  (`memory/review_cadence.ex` syncs a `memory-index-rebuild` job).
- **Known hazards** — every retrieval full-scans the memory filesystem
  (the compiled index exists but Active Memory does not use it); a hard
  recency floor excludes entries older than 10× half-life (300 days at
  defaults) — fatally wrong for durable facts; `source_ref` thread
  affinity is substring-matched.

The consent line: the trust spine says "memory review remains explicit",
and four ADRs carry "no automatic memory promotion" non-goals. The backlog
entry's staged posture — system-consolidated memories land as reviewable
drafts or a distinct system-proposed tier, and **only reviewed entries
become prompt context** — is adopted here as the binding rule, not
relaxed.

## Superseded Decision History (non-normative)

Sections 1–7 preserve the original and first-pass decision history. Where they
name an open LD-R choice or conflict with §8, §8 and ADR 0092 control; those
older passages are not implementation alternatives and M1 is calibration-only.

### 1. Three-tier memory model

- **STM / working memory** — the volatile session scratchpad (ETS, TTL).
  v1.3 formalizes its data-safety contract (what may never enter it, and
  deep-merge patch semantics for nested updates — the folded v0.14 gaps)
  without persisting it.
- **Episodic usage history** — the existing durable stores
  (conversations, traces, objectives, jobs runs). v1.3 treats them as
  **read-only raw material**; it does not add a parallel history store.
- **LTM — consolidated user memory** — durable facts and preferences
  about the operator, produced by consolidation and by the existing
  explicit paths, retrievable at prompt time once reviewed.

### 2. The consent boundary: propose → review → retrieve

- Consolidation output lands in a **system-proposed tier that is inert**:
  visible in the review surfaces, bulk-acceptable, individually editable
  or rejectable — and **never retrievable into any prompt while
  unreviewed**. Only operator-reviewed `:kept` entries enter prompt
  context. The explicit-review line holds; this ADR does **not** relax it,
  and any future bounded-class relaxation requires its own operator-signed
  amendment.
- **Unmaking a fact is also an operator act.** Consolidation may detect
  that a newer statement contradicts a `:kept` entry, but it may not
  retire that entry: it writes a *supersession proposal* (§7) that names
  the target and the evidence, and the entry stays valid and retrievable
  until the operator reviews it. "Only the operator makes memory" governs
  invalidation exactly as it governs creation — there is no system path
  that removes a fact from prompt context.
- **Historical LD-R1 (resolved by §8): the proposal representation** — an
  additive `review_status: :system_proposed` value on memory entries
  (default posture: keeps review in the existing memory panel with
  bulk-accept), versus routing through the v0.47 `memory_update` draft
  pipeline (stronger provenance ceremony, heavier UX). The resolved choice
  must preserve: additive schema only, provenance (source refs +
  consolidation run id), idempotent dedupe keys, and the
  never-in-prompt-while-unreviewed invariant.

### 3. Consolidation: a bounded, local, audited job

- A periodic **managed job** (the ReviewCadence pattern: a
  `memory.consolidation.*` settings fragment syncs a named scheduled job)
  targeting a registered consolidation action through the ordinary Jobs →
  `Actions.Runner` path. Runs are bounded (per-run source and proposal
  caps), resumable, and record a run summary.
- Sources: conversations, traces, objective history — local reads only;
  consolidation performs **zero egress** beyond the operator's configured
  local model if model-assisted extraction is used (resolved by §8).
- **Only operator-authored content may originate a fact.** Extraction
  reads operator-authored turns (`conversation_messages.role`); assistant
  turns are readable as disambiguation context but can never be the
  origin of a proposal. Allbert's own speculation ("so you prefer X?")
  must not return as a proposal carrying real provenance — that is the
  documented sycophancy failure mode, and it is the memory-side reading
  of the standing rule that model output grants no authority by itself.
  Conversations are the **primary** source; traces and objective history
  are supplementary, because `runtime.trace_default` may never have been
  enabled and the trace corpus can legitimately be empty.
- Every proposal passes the sensitive-content filters (the intent-side
  secret blocklist generalized + `Security.Redactor`) **before** it is
  written; a proposal that trips the filter is dropped and counted, never
  stored redacted-in-place.
- **Historical LD-R2 (resolved by §8): extraction method** — deterministic
  heuristics first (the TraceIndex pattern-type precedent) with
  local-model-assisted extraction as the bounded second stage, versus
  model-primary. Default posture: deterministic-first, model advisory,
  fail-closed to fewer proposals; M1 calibration sets the measured
  precision floor the v1.3 plan gates on (seeded-corpus precision — no
  synthetic-template evidence).
  A **recall floor is gated beside the precision floor.** The precision/
  recall trade-off is persistent, and a fail-closed extractor satisfies a
  precision gate by proposing almost nothing — passing the gate while
  silently failing the Operator-Visible Win. Both floors are measured on
  the same real seeded corpus and both are release blockers.
- Default-enabled posture is an **operator decision at M1 sign-off**
  (plan LD; default proposal: enabled with a conservative weekly cadence,
  kill switch `memory.consolidation.enabled`, because output is inert and
  local — but the operator may set default-off).

### 4. Retrieval evolution (Active Memory stays the substrate)

- Retrieval remains **deterministic and lexical** — embedding-backed
  recall stays parked under System Memory Distillation. Consolidation
  changes corpus *scale*, so v1.3 makes Active Memory consume the
  compiled index for candidate listing (replacing the per-turn full
  filesystem scan) with a measured retrieval budget against the plan's
  large-corpus fixture.
- Retrieval filters on **validity as well as review status**: candidates
  are `review_status: :kept` **and** currently valid per §7 (`retracted_at`
  unset, and the as-of instant inside the valid-time interval). A
  superseded fact is structurally unreachable rather than merely
  outranked — feeding a fact and its replacement into the same prompt
  block is the failure the lifecycle exists to prevent.
- **LD-R3 (amended 2026-07-28 — subsumed by §7).** Durable-fact recency
  was open because the hard staleness floor excluded entries older than
  10× half-life, which is fatally wrong for durable facts. Validity
  replaces recency as the survival criterion: a valid fact is retrievable
  regardless of write age, and the floor applies to validity, not to
  age-since-write. No floor-exempt class, reviewed-at refresh, or
  per-class half-life is needed. LD-R3 survives only as the pruning-UX
  question — how retired facts are surfaced and eventually removed
  through the existing review/prune surfaces.
- LTM entries are user-global: they ride the existing
  identity-inclusion scope path (namespace-scoped inclusion beside
  thread/app affinity), not a new scope machine.
- **Historical LD-R4 (resolved by §8): retrieval budget accounting** — byte
  budgets (today's 8,000-byte block) versus estimated-token budgets, and
  the LTM/general split within the budget.

### 5. Prompt seam and zero-shot claim

- v1.3 injects LTM context at the existing direct-answer/vision seam
  only; widening to routed app actions, objectives, or coding turns is
  explicitly future scope.
- The flagship claim is **measured**: the plan carries a seeded-facts
  acceptance corpus — operator-reviewed facts present → the model answers
  designated questions zero-shot without re-deriving; the uplift and the
  token delta are recorded from real runs, and this scenario is an
  automated regression before any operator validation (the v1.1 M12.12
  lesson).
- **Abstention is measured beside uplift.** Recall of a stored fact and
  restraint when no fact is stored are separate abilities, and a corpus
  that only rewards answering selects for confident invention. The
  acceptance corpus therefore carries negative rows: a question whose
  fact was never stored, one whose fact is still an unreviewed proposal,
  and one whose fact has been superseded — each passing only when the
  answer declines to assert rather than producing the absent, unreviewed,
  or retired value.
- **Historical LD-R5 (resolved by §8): consolidation model usage** — whether
  extraction may call the configured local model, and under which
  fan-out/budget bounds (the v1.1 substrate is available but not
  required).

### 6. Conversation history search (historical; superseded by ADR 0092)

The backlog marks Conversation-History FTS and cross-thread retrieval as
"foundational inputs — research to confirm". M1 decides whether bounded
FTS ships in v1.3 as the consolidation/recall substrate or records an
operator-signed deferral (the no-unilateral-deferral rule applies). If it
ships: additive index/table only, local-only, no retention change.

**Decision criteria (added 2026-07-28), so M1 resolves this on evidence
rather than preference.** FTS is *in* if the M1 calibration shows
deterministic extraction needs cross-session candidate lookup that
per-thread listing cannot serve inside the per-run cap — concretely, if
conflict detection (§7) must scan more threads to find the prior claim
than the run budget allows. It is *out* if per-thread listing plus the
consolidation window covers detection at the measured corpus size. If it
ships, the index is external-content FTS5 over `conversation_messages`
with the exact documented trigger form (`INSERT INTO fts(fts, rowid, …)
VALUES('delete', old.rowid, …)` before re-insert on update) — the
malformed-trigger variants silently corrupt the index.

### 7. Fact lifecycle (historical mutable shape; superseded by §8)

Added 2026-07-28. The original decision modelled memory as append-only:
idempotent dedupe caught a fact being *restated*, but nothing handled a
fact being *contradicted*. Left that way, consolidation accumulates
mutually exclusive `:kept` entries ("prefers metric units" and "prefers
imperial") and retrieval feeds both into the same prompt block. The
surveyed deployed systems all claim supersession handling and all
underperform on it; the measured wins come from resolving conflicts
deterministically and from removing contradicted claims from the
retrieved context rather than out-ranking them.

- **Two time axes, both recorded.** *Valid time* (`valid_from`,
  `valid_to`) is when the claim holds in the operator's world. *Transaction
  time* (`recorded_at`, `retracted_at`) is when Allbert learned or retired
  it. The pair makes "what is true now", "what was true in March", and
  "what did Allbert believe in March" separately answerable, and makes a
  correction distinguishable from a change — the operator moving house is
  not the same event as Allbert having mis-recorded the old address.
- **Nothing is overwritten or deleted.** Supersession sets `retracted_at`
  on the prior entry and links `supersedes` / `superseded_by`, with
  `revision` counting the chain. The retired entry stays on disk, stays
  auditable, and stays reachable through the history surfaces. This is
  the memory-side reading of the standing preserve-user-data rule:
  consolidation is a producer, never a destroyer.
- **Detection is deterministic first.** A conflict is a new claim on the
  same subject/predicate for the same namespace; resolution in the common
  case is newest-valid-wins by comparing recorded instants — an integer
  comparison, not a model judgment. Model assistance (resolved by §8) may only
  *propose* that two claims concern the same subject; it never decides
  which wins. Ambiguous conflicts are proposed to the operator unresolved
  rather than guessed.
- **Retrieval is as-of.** Candidates are filtered to entries valid at the
  as-of instant, which defaults to now. As-of is an **explicit
  parameter** on the retrieval API, the history surfaces, and the CLI —
  it is never inferred from natural language. Deriving "last year" from a
  chat turn is multi-hop temporal reasoning, the weakest measured area in
  the literature, and it stays a non-goal.
- **Additivity holds.** Entries are markdown (ADR 0002), so the lifecycle
  fields are frontmatter; the compiled index gains nullable columns. No
  existing field changes meaning, and an entry written before v1.3 reads
  as valid-from-unknown, never-retracted — exactly its current behavior.
- **The consent boundary covers the whole lifecycle** (§2): consolidation
  proposes supersession, operator review enacts it. An unreviewed
  supersession proposal changes nothing about what retrieval returns.

## Decision

### 8. Source consent, append-only claim streams, and Forget

Added by the operator-signed second readiness pass on 2026-07-28. This section
supersedes conflicting source, proposal, search, and lifecycle language in
§1's episodic-source list, §§2–3, and §§6–7.

#### Memory CollectionPolicy is principal-verified and consumer-specific

Memory collection and Search eligibility are separate consumer decisions. The
verified `private_operator` trust class does not itself grant either consumer
access. Each consumer records an origin-scoped grant:

- `local_operator` covers verified local Web, CLI, and TUI. Search's local
  grant is implicit/default-on; Memory's is explicit/default-off.
- `mapped_operator_dm` covers current and future verified mapped one-to-one
  operator DMs after one clear grant for that consumer. It is not one prompt
  per DM channel. Group/shared conversations, programmatic callers, and
  unknown principals remain excluded.
- `e2ee_operator` is an additional audited overlay for the named consumer.
  Enabling ordinary local or mapped-DM access does not enable E2EE-origin
  collection or projection.

Canonical invalidation is shared; consumer-grant invalidation is not. Canonical
deletion, lost canonical visibility, principal invalidation, or an unverified
principal remap makes the source unavailable to both consumers. Once a remap is
verified, each consumer re-evaluates it under its own current origin/E2EE grant.
Revoking Memory collection, including its E2EE overlay, immediately invalidates
affected pending Memory proposals but does not erase Search eligibility.
Revoking Search eligibility removes or suppresses Search results but does not
invalidate a Memory proposal or a separately reviewed kept claim. A kept
Memory claim remains governed by its separate operator review and current
namespace scope.

A `role == "user"` field is not identity proof. Only a message whose principal
the canonical conversation boundary verifies as the operator may originate a
claim. Assistant messages may be read only as bounded, transient
disambiguation context and are never persisted as proposal provenance or claim
authority.

That check is implementable from durable, additive admission evidence rather
than a current-role guess. Every provider-backed message reference records the
exact `thread_channel_ref_id` used for admission, an immutable domain-separated
`origin_principal_digest` snapshot, and its `principal_normalizer_version`.
The thread-ref foreign key identifies the exact origin row; the separate digest
is required because that row is updated as provider metadata changes. Corpus
reauthorization normalizes the currently enabled external identity mapping with
the recorded version and requires its digest to match both the admission
snapshot and the canonical message's operator/user ownership. It never stores
a current mapping version as substitute authority.

Verified local Web, CLI, and TUI messages need no fabricated provider row: they
remain eligible only when canonical `message.user_id` matches the requested
operator and the current source classification is local. Assistant rows carry
assistant authorship and may be Search-visible but never originate Memory.
Existing provider-backed rows are backfilled only when exactly one durable
thread ref for the message's canonical thread/channel/account contains a
principal digest that currently maps to that same canonical operator. Ambiguous,
missing, disabled, or conflicting evidence is marked
`legacy_principal_unverified` and is ineligible for both Memory collection and
external-history Search until an explicit identity repair; implementation never
guesses or broadens access to preserve recall.

The shared Corpus contract is schema version `1` and pages canonical messages
in ascending `(inserted_at, id)` order beneath an inclusive high-water bound.
Snapshot state binds operator, source policy, and `eligibility_epoch`; page
size defaults to `200` and rejects values above `500`. Batch reauthorization
accepts at most `100` unique refs and preserves input order with typed
unavailable reasons. Memory disambiguation receives the source plus at most
four preceding and four following same-thread messages, never more than nine
messages or `32_768` UTF-8 bytes; it drops farthest context first and marks
truncation. It never silently truncates the authoritative source envelope.

**Span provenance makes that enforceable for consolidation-produced
conversation proposals.** Every semantic field records the canonical source
id and digest, UTF-8 byte start/end, raw-span digest, normalized field value,
and a versioned deterministic transform kind. The complete v1 allowlist is
`identity_v1`, `trim_ascii_whitespace_v1`, `ascii_lower_v1`,
`operator_pronoun_v1` (`I | me | my` to the authenticated operator subject),
and `explicit_iso8601_date_v1` (an already explicit `YYYY-MM-DD` span). No
parser infers a synonym, date, number, or replacement text; arbitrary model
rewriting cannot create grounding.
At review, the canonical span is read again and its source/span digest must
still match. Bounded assistant context may resolve deixis only to another
operator-authored span. If a field value exists only in assistant text, the
extractor abstains and counts the refusal.

This grounding rule does not invent conversation spans for explicit operator
remember/update actions, confirmed manual imports, or confirmed legacy drafts.
Those paths carry typed actor/action provenance and their exact input or
revision digest instead. Trace and objective identifiers may be attached as
typed correlation references, but consolidation does not read trace/objective
bodies as claim sources. Secrets and credential-shaped material are hard-
dropped before any proposal record is written. The earlier formulation asked
acceptance to prove assistant text carried "no corroboration weight", which is
not measurable once it enters an opaque model prompt; the persisted grounding
record is the deterministic gate.

#### Proposals retain claims, not transcripts

One Memory-owned set of additive tables in the existing application Repo stores
ordinary proposals, protected stubs, and frozen review results. It is
authoritative for inert review state only, never for kept claims, and does not
add another database. An ordinary proposal persists the normalized claim,
typed canonical source identifiers, source digest, collection class,
classifier result, and proposal revision id. It does not copy a transcript.
Review re-authorizes those typed sources and may fetch only a bounded, redacted
excerpt for display.
Proposal rows follow the existing Repo backup/restore lifecycle. The redacted
portability envelope exports no proposal content; a raw/full Home backup may
contain it and therefore sits outside Forget's active-store erasure guarantee.

Facts about a third party, minor, or dependent are protected proposals. Before
review they persist only a redacted stub and typed evidence references; they
require individual review and are never eligible for Keep All. Ordinary batch
review freezes the visible proposal revision ids and digests, records a durable
per-item outcome, allows explicit partial success, and resumes idempotently.
An item that became stale, changed digest, lost eligibility, or failed
re-authorization is skipped rather than accepted from the old batch snapshot.

Keep/Edit has an explicit cross-store recovery protocol rather than pretending
the Repo and markdown filesystem share a transaction. The frozen proposal
revision/digest, operator/namespace, and normalized review-decision payload
digest (including edited claim, validity, and relationship fields) derive a
deterministic claim-transition id. Review first persists an `applying` phase,
temporarily freezing the normalized decision payload and digest in the existing
proposal row, then appends the canonical claim transition with that id, then
reduces the proposal to its content-free terminal outcome. On retry or startup
reconciliation, a matching canonical transition completes the terminal
reduction; an absent transition repeats current Corpus principal/grant/digest/
classification authorization before safely retrying the same frozen payload.
An already-ineligible source becomes stale. The last successful authorization
before append is the linearization point; a later canonical deletion changes
provenance availability but does not revoke the reviewed claim. A changed
decision payload or conflicting transition fails closed for a new preview/
operator repair. Crash injection after each phase must prove that
review cannot append the same claim twice, accept a different edit under the
old id, or leave a successfully kept proposal indefinitely content-bearing.

Source revocation or deletion invalidates an unreviewed proposal immediately.
A separately reviewed and kept Memory claim remains until an explicit Memory
archive, correction, retirement, or Forget action; deleting conversation
history is not an implicit deletion or retrieval denial of operator-curated
Memory. Retrieval still rechecks the claim's current operator/namespace scope;
the lost source changes provenance availability, not the authority of the
operator's separate review decision.

After Keep/Edit successfully appends the authoritative claim revision, the
proposal record is reduced to content-free result/provenance identifiers. It
does not retain a second copy of normalized claim text. Frozen batch results
store proposal/revision ids and outcomes, not claim content, and the bounded
review excerpt is fetched transiently rather than cached durably.

#### Proposal, extraction, and retrieval choices are closed

The proposal representation is one inert durable Memory proposal record (or
protected redacted stub), not a `:kept` claim and not an automatic route through
the v0.47 draft pipeline. Keeping or editing an eligible proposal appends the
authoritative reviewed claim revision. This resolves LD-R1 without creating a
second review engine.

Deterministic identity, consent, secret, classification, normalization,
dedupe/conflict, and suppression gates are authoritative. One configured local
model may advise bounded extraction. If it is unavailable or fails, the run
produces only the deterministic high-confidence subset or abstains; there is no
hosted fallback. Consolidation defaults disabled until the collection grant,
then uses the cadence and caps fixed by the active plan. These decisions resolve
LD-R2 and LD-R5.

The managed consolidation action requires the additive `:memory_propose`
permission. A current verified `Memory.CollectionPolicy` grant authorizes only
bounded writes of inert proposal records, so the weekly job does not prompt on
every run. `:memory_propose` cannot keep, edit, archive, restore, or Forget a
claim. Those remain the existing operator-dispatched Memory write/review paths,
with Forget carrying its separate destructive confirmation. Job identity and
schedule metadata grant nothing.

Retrieval stays deterministic and lexical over the complete rebuildable Memory
projection and enters only the existing direct-answer/vision prompt seam. M1
freezes that budget at `8_000` UTF-8 bytes, `top_k: 5`, and `2_048` bytes per
chunk. The hand-authored fixture pins the optional advisory reference profile to
local-only `local_ollama/llama3.2:3b`; deterministic-only extraction may pass
the same gate. Micro-averaged eligible precision is `>= 0.90`, eligible recall
`>= 0.80`, and required abstention over assistant-only, trace-only, ambiguous,
question, ephemeral, and hard-drop rows is `>= 0.95` over `20` frozen rows (at
most one miss). All four temporal-update
cases, both protected secret/financial drops, and both protected individual-
review routes must be correct. The eligible denominator is `14`; a true
positive requires the expected decision and exact allowlist-grounded normalized
fields, precision is `TP / (TP + FP)`, and recall is `TP / 14`. Protected
review stubs are outside both. At a warmed single-caller
projection of `10_000` current claims, canonical revalidation plus prompt
selection is p95 `<= 75 ms` and p99 `<= 250 ms` over `200` fixture-derived
queries on each packaged validation host. These are calibration outputs, not
open ownership or authority choices. This resolves LD-R4 without adding a new
prompt or retrieval architecture.

#### The canonical Memory record is an append-only markdown claim stream

Each claim has a stable claim id and an ordered stream beginning with an
accepted keep/edit revision, followed only by reviewed correction/change,
archive/restore, retirement, manual-import confirmation, and review transitions.
Unreviewed proposals stay in the inert proposal store. Each claim revision
records its previous-revision hash and own canonical-content digest. Compiled
Memory projections are disposable.

Digest links alone cannot distinguish an action-written transition from text a
file editor fabricated. Therefore every post-v1.3 authority-bearing native
transition records its non-secret integrity-key reference/version and an HMAC-
SHA-256 tag over the versioned canonical transition tuple fixed by ADR 0002.
Accepted keep/edit, explicit remember/update, correction, archive/restore,
retirement, legacy adoption, and review transitions all use the native-
transition domain. A raw well-formed append has no such tag and is a pending
manual revision, not authority: it remains quarantined until the operator
confirms that exact revision through registered action
`confirm_manual_memory_revision`. That action appends a content-free
`manual_import_confirmed` transition
which binds the unchanged pending revision and whole prior-chain digest under a
separate manual-confirmation domain. Rebuild accepts it only when the local tag
verifies and no content revision intervenes. A broken hash link, duplicate or
reordered revision, mutation/removal of prior content, fabricated native event,
or missing/invalid tag quarantines the claim. No Repo ledger becomes a second
authority, and file content never silently acquires authority.

The one 32-byte per-Home secret is auto-provisioned before the first native
write using shared ref `secret://system/integrity_v1` (record version `1`)
through the existing Settings Secrets/Key Custody implementation's serialized
system-secret `fetch_or_create` operation; it commits before any claim write.
Claim transitions, manual confirmation, destination-
chain confirmation, and Forget suppression use the four exact domains in ADR
0002. A Home with no durable reference to the shared version may create it once;
any TUI/Memory/Search/delete-preview reference prevents silent replacement.
Missing native-event
keys quarantine affected streams and block new writes; a missing Forget key
also keeps proposal production fail-closed. There is no automatic material
rotation. Settings master-key changes rewrap the same secret, and referenced
old versions remain available. This operational dependency is intentionally
one helper on the existing key seam, not a Memory key service.

A same-Home restore with the original secret verifies normally. Moving claim
files to another Home does not export that secret, so structurally valid streams
remain readable but quarantined there. After an exact preview, registered
action `confirm_destination_memory_chain` may append
`destination_chain_confirmed`, authenticating the unchanged
whole-chain digest under the destination key and destination-chain-confirmation
domain. That is a new destination-operator grant, not a claim that the source
tags verified locally; it rewrites
nothing and any chain change requires a new confirmation. This preserves
readable file portability without creating key export or cross-Home trust
infrastructure.

Projection updates are retryable consequences of canonical transitions. An
incremental accepted/reviewed mutation advances a projection revision; only a
full rebuild or schema/configuration change promotes a new generation. Before
prompt insertion, the bounded top-N projection candidates are rechecked through
the canonical claim reader for claim id, revision digest, kept/current state,
namespace, and Forget suppression. A mismatch is omitted immediately and
queues ordinary projection repair. Thus a crash after archive, correction, or
Forget cannot make a stale projection authoritative or place the stale fact in
a prompt.

The generation/control key `full_build_source_watermark` records the exact
canonical input digest used to construct that full generation and does not
claim to describe later incremental refreshes. Incremental refresh stays
bounded to the affected claim, advances `projection_revision` in the same
SQLite transaction as its projected rows, and retains that claim's canonical
revision digest. No consumer may treat the full-build watermark as current
source equality after `projection_revision` advances. A complete rebuild
recomputes the watermark. The legacy unqualified `claim_stream_watermark` is
schema-1 disposable state and causes rebuild rather than field-by-field
migration.

The fixed projection root is `<ALLBERT_HOME>/projections/memory/`, containing
`control.json`, `current.sqlite3`, `previous.sqlite3`, and at most one live
`build-<UUIDv7>.sqlite3` plus SQLite sidecars. The shared `projections/` root is
excluded from authoritative backup/export. Schema-2 control and generation
metadata preserve plan LD 84's fixed-file layout and compatibility fields, with
the watermark clarification above as the only schema-1 metadata replacement;
fixed-file promotion uses no symlink, pointer service, Ecto Repo, or generic
projection registry.

Startup ownership is ordered without adding a coordinator. The supervised
`Memory.Projection` process first discovers and verifies every tombstone and
installs the fail-closed suppression set; it does not announce retrieval-ready
or allow proposal production before that step completes. It then validates the
current projection generation against canonical claims and records whether
repair is needed. Pending tombstones or proposal/legacy-draft `applying` rows
cause a bounded dirty kick of the existing `memory-index-rebuild` managed
identity. Its registered repair action always completes tombstone cleanup
before retrying applying rows, then repairs the projection. Every applying retry
also passes through the claim writer's final tombstone check, so startup cannot
recreate a forgotten value. If Jobs is paused or repair fails, reads and
proposal production affected by pending recovery remain suppressed/degraded;
unrelated canonically verified claims may still serve. A missing tombstone key
retains the stricter global proposal-production pause. The explicit repair
action remains available, and the projection process never performs domain
effects or bypasses Runner itself.

The two temporal axes are genuine and separate:

- **valid time** is when the fact applies in the operator's world; and
- **known time** is when Allbert held a reviewed revision as current.

Both axes support explicit as-of reads and default independently to now. A
later recorded statement does not automatically win. Conflict detection may
propose a relationship, but operator review decides whether it is a correction
of the prior record, a real-world change with a new validity interval, or an
unresolved conflict. This supersedes §7's “newest-valid-wins by recorded
instant” language and any implementation that mutates the prior markdown entry
in place.

Pre-v1.3 entries project as deterministic synthetic revision 0 streams without
a bulk rewrite or retroactive tag. ADR 0002 fixes their synthetic claim id as
UUIDv5 namespace `3a933b90-6d58-5d8c-9cdb-1233c996532f` over
`legacy-memory-v1\0<category>\0<normalized-Home-relative-path>`; it never reads
or hashes claim text or its normalized value. Before adoption, a rename is a
removed legacy source plus a newly discovered one. Their first lifecycle
mutation appends the requested signed native transition with a
`legacy_adopted` envelope binding the synthetic id and complete legacy-file
digest; the embedded id then survives later moves. Two files declaring one
embedded id, or an otherwise impossible synthetic collision, quarantine both
instead of selecting by timestamp or path. Forget suppression remains value-
bound, so moving or copying an unadopted forgotten value under a new synthetic
id cannot resurrect it. Archive/retire remains a reversible appended transition
and retains the full claim history.

All write paths use the single per-claim serialized
`Memory.Claims.append(claim_id, expected_tail_digest, transition)` interface
from ADR 0002. Under its
claim lock, the writer rereads the full chain, rejects a stale expected tail,
recognizes an identical deterministic transition as a retry, and rechecks
pending/completed tombstones immediately before commit. It writes one complete
same-directory temporary file, syncs it, atomically renames it, and syncs the
parent directory before unlocking. Replacements preserve the existing mode;
new streams use the private Memory-file default. Detected concurrent raw edits
are preserved and return a typed stale-tail/manual-repair result; abandoned
temporary files never enter discovery. This serialized compare-and-append is the
linearization seam for proposal review, explicit actions, legacy drainage,
Archive, and Forget-adjacent writes—no surface implements its own writer.

#### Confirmed Forget is the narrow immutability exception

Registered action `forget_memory_claim` is a separately confirmed, audited
operator action with a tombstone-first, fail-closed recovery protocol. Its
durable confirmation binds claim id,
expected tail digest, suppression-normalizer version, and the closed reason code;
the exact claim preview is fetched transiently and is not copied into the
confirmation record or audit. Before removing claim content it writes a single
content-free Markdown tombstone at
`<memory_root>/tombstones/<claim_id>.md`, resolving `memory_root` through
`AllbertAssist.Paths`, carrying the non-content-derived claim id, deletion time,
actor, closed `reason_code`, `pending | complete` phase, non-secret key
reference/version, normalizer version, and a keyed per-Home suppression token.
The durable reason is one of `operator_requested`, `privacy`, `incorrect`, or
`expired`. Any human
explanation is transient and redacted, never copied to the tombstone,
confirmation result, trace, or audit. This file, not a Repo ledger or projection
row, is the durable suppression/recovery authority. The token is an HMAC of the
versioned normalized forgotten claim under the Forget domain fixed above; it
stores neither the value nor a reversible digest. A pending tombstone
immediately denies proposal production and canonical Memory retrieval exactly
as a complete one does.

The action then idempotently removes the canonical claim stream and every
active content-bearing record linked by claim/transition/source digest. That
traversal includes proposal, applying-review, frozen-batch, legacy memory-
suggestion/draft metadata, and legacy draft artifact payloads; it preserves
only content-free ids, digests, typed outcomes, and provenance references.
It then rebuilds or repairs the disposable projection from remaining claims,
retires obsolete generation files/sidecars, and marks the tombstone complete.
Startup and explicit retry reconcile pending tombstones in the order above.
Review excerpts are transient and must not survive the request. The versioned
predicate suppresses re-proposal or applying-retry append of that exact
forgotten claim while allowing a genuinely new value for the same subject/
predicate and prevents a future normalizer change from silently resurrecting
the old value.

The success guarantee is logical and product-facing: no Allbert Memory
Interface returns the claim, no prompt receives it, no active proposal carries
it, and no openable/current or startup-recoverable projection generation
contains it. Core SQLite `secure_delete` and a bounded WAL checkpoint are used
for affected Repo proposal rows where supported, and obsolete disposable
projection databases are removed wholesale,
but SQLite free pages, a busy/untruncated WAL, deleted files, and storage media
may retain forensic remnants. Those physical cleanup steps are bounded best
effort and are never described as cryptographic or forensic erasure. A failed
required logical/rebuild phase leaves the tombstone pending and visible for
retry rather than returning a false completed result.

Forget makes no promise about copies outside active Allbert-managed data,
including pre-Forget Repo/Home backups, snapshots, exports, filesystem
remnants, or storage-device wear leveling. Those boundaries are disclosed
before confirmation.

**Forget also does not delete the conversation the claim came from.** The
originating message remains canonical and remains in the Search projection, so
a conversation search still finds the operator's original statement while the
claim itself is unretrievable and permanently blocked from re-proposal. That is
the intended separation — Forget removes what Allbert concluded, canonical
deletion removes what was said — but because v1.3 ships conversation search in
the same release, the retained searchable conversation is named in the
pre-confirmation disclosure beside the backup boundary, and the disclosure
points to the confirmed canonical conversation delete action for an operator
who wants both.

For the boundary this ADR relies on, that action accepts
`target_kind: message | thread` and binds confirmation to the exact
conversation-owned cascade. A message preview includes its row id/version/
content digest and every message-reference row id/version. A thread preview
also includes the thread row id/version, the stable ordered set of message
ids/versions/content digests, and every thread/message-reference row id/version.
The canonical Repo transaction recomputes the whole set before deleting it; any
addition, removal, or version change makes the approval stale. The already-
approved confirmation id and bound preview are the retry key rather than a
fictional transaction with the filesystem confirmation store. After a commit,
the same approved request against an absent target returns `already_deleted`
and re-drives idempotent Search/proposal reconciliation; a fresh request for an
absent target returns `not_found`.

The cascade removes only Conversations-owned canonical message/thread and
provider-reference rows, then causes Search reconciliation. Cross-domain
Objectives, traces, jobs, drafts, and separately kept Memory are preserved;
their source links become unavailable and any copied content they independently
retain remains governed by their own lifecycle. The pre-confirmation disclosure
names those active Allbert-managed copies as well as the messaging provider's
server copy, exports, snapshots, and backups. The action is deliberately
canonical-copy deletion, not a hidden cross-domain erasure cascade. An operator
reading "Forget" or canonical delete as global "erase" would otherwise be
misled about precisely the thing they were protecting.

The current redacted portability envelope carries neither suppression tokens
nor key material and its import remains dry-run, so it makes no cross-Home
suppression promise. A same-Home full restore preserves suppression only when
both tombstones and their existing Key Custody secret remain available. If a
copied/restored tombstone's key reference is missing or mismatched, proposal-
producing actions fail closed with `tombstone_key_unavailable` rather than
silently resurrecting forgotten content. A genuinely fresh Home/new key has no
knowledge of another Home's forgotten values; that limitation is documented,
not hidden behind a key-export subsystem.

#### Search is a separate read product, not a Memory producer

ADR 0092's Search Central supersedes §6's conditional external-content FTS
design. Consolidation reads canonical conversations through
`Conversations.Corpus` under `Memory.CollectionPolicy`; it never reads the
Search database or Search result pages. Search has no promote-to-Memory bridge.
An explicit operator summarize action may send the selected, re-authorized
search result set to the model for that response, but summary generation does
not create a proposal or kept Memory.

### 9. One memory system, reached through absorbed legacy shapes

Added by the operator-signed third readiness pass on 2026-07-28. §8 designed
the new memory model without dispositioning what already exists, so a
code-level cross-check found five live subsystems that would have shipped
beside it: the `search_memory` action, the compiled memory index with its
`memory-index-rebuild` managed job and `memory.review_cadence` setting, the
`prune_nominated` review status, `memory.auto_promote_sensitive_entries`, and
the v0.47 `memory_promotion` / `memory_update` discovery drafts. Two of them
contradicted stated contracts outright — one an over-broad "sole search engine"
claim, the other a settings key whose name asserts the automatic promotion this
ADR exists to forbid.

v1.3 absorbs each into the new model. Absorption is **behavioral, not
deletion**: every existing action name, settings key, and request shape keeps
responding and routes into the new implementation, while the legacy store or
job stops being a second authority. Deletion is not available, because removing
a public shape inside the v1.0 Tier-2 freeze is a separate operator decision
with its own major-version process; `delete_memory_entry`'s existing role as a
compatibility alias for archive is the precedent. The per-item table lives in
the v1.3 plan under Current Code State.

The producer cutoff is at
`AllbertAssist.SelfImprovement.Discovery.suggestion_type/1`: after v1.3 it no
longer creates new `memory_promotion` or `memory_update` suggestions. The
legacy suggestion/store schemas and promote actions continue recognizing both
kinds so existing rows can drain. Promotion re-authorizes the exact frozen
draft digest, requires the existing operator confirmation, and appends through
the one authoritative claim writer as typed `legacy_confirmed_draft`
provenance. It never writes a kept entry through the old direct Memory path and
does not fabricate conversation-span provenance that an old draft cannot have.
After the canonical append commits, the drain protocol replaces the legacy
draft's YAML payload, promotion detail, and content-bearing diagnostics with a
content-free terminal outcome and removes its separate artifact file. The
public action/result shape remains callable, but drained content fields return
empty/unavailable rather than retaining a second claim copy. Until that scrub
commits, the draft stays in a recoverable `applying` phase keyed by its exact
draft/transition digest. Startup uses §8's ordered managed repair, and Forget
traverses this phase plus the metadata/artifact before completion. A retry whose
value matches a pending or complete tombstone is reduced to a content-free
`forgotten` outcome and can never reappend the claim.

Compatibility is per caller, not a new second index. `search_memory` preserves
its response shape and bounded canonical-markdown fallback when the projection
is disabled or unavailable. Intent preserves its existing disabled=no-indexed-
candidate behavior, while direct-answer Active Memory remains independently
projection-backed. `compile_memory_index` preserves its public shape while
targeting the retained `memory-index-rebuild` managed entry; the review cadence
and configured caps feed that one projection. `prune_nominated` and the
existing prune action route to reversible archive transitions through the
`delete_memory_entry` compatibility semantics; `restore_memory_claim` reverses
them. The auto-promote
setting remains readable/writable but deprecated and inert; implementation does
not rewrite operator state merely to make it false.

At upgrade, only a row with exact legacy
`template_name: memory-index-rebuild`, `managed_by: memory.review_cadence`, compatible target,
and canonical local operator is adopted in place. Its id, run history, allowed
cadence, and pause survive while new owner/spec metadata and the projection
target are installed atomically. A template-only or otherwise ambiguous row
degrades as `managed_name_conflict`; it is never guessed into system ownership.

The consequence worth stating at ADR level: after v1.3 there is exactly one
memory-index authority, one managed memory-index entry per Home, and one
system-suggests-memory surface. An operator sees one review workflow, not two,
and no code path honors an auto-promotion setting.

## Consequences

- Allbert gains durable, operator-curated knowledge of its operator with
  a consent story that strengthens rather than erodes the trust spine:
  the system may propose; only the operator makes memory.
- One memory system replaces the previous index, suggestion pipeline, and
  memory-search entry point; legacy shapes remain callable and route into it.
- Every direct answer can start from the right context — the measured
  zero-shot uplift is the flagship's acceptance bar, not an aspiration.
- Retrieval cost stops scaling with corpus size (index-backed candidates)
  — a precondition for consolidation being safe to leave on.
- The v0.47 store/promotion shapes remain only to drain existing drafts; their
  discovery producer stops creating new memory drafts, exact-digest confirmed
  legacy promotions use the authoritative claim writer, and explicit
  "remember" paths use that same writer.
- Collection eligibility is principal-verified and re-authorized at review;
  message role and stale source snapshots grant nothing.
- Append-only claim streams preserve reviewed history and quarantine manual
  tampering, while confirmed Forget remains one narrow, honest deletion
  exception.
- Native claim authority now depends on one existing-Key-Custody per-Home
  integrity secret; losing referenced material fails closed and destination
  portability requires explicit whole-chain confirmation.
- Canonical conversation deletion is exact and retryable but intentionally
  preserves cross-domain records; its disclosure names those retained copies.
- Search and Memory remain independent consumers of the conversation corpus;
  neither one's projection is authority for the other.
- v1.8's profiling reads the same episodic sources and proposes through
  an analogous confirm-first boundary (ADR 0090) — the two releases share
  the propose/review grammar deliberately.

## Non-goals and guardrails

- **No automatic promotion to `:kept`** — bulk-accept is an explicit
  operator act on visible entries; nothing self-promotes. The four ADR
  non-goal anchors stand.
- **No embeddings, no learned ranking, no trained memory artifacts**
  (System Memory Distillation stays parked).
- **No egress**: consolidation reads local stores and may use only the
  configured local model under §8; nothing leaves the machine.
- **No automatic retention or deletion changes.** Pruning stays
  operator-driven through existing surfaces, and supersession/archive retains
  history. The separately confirmed §8 Forget action is the sole intentional
  content-deletion exception.
- **No inferred temporal queries.** As-of retrieval is an explicit
  parameter; natural-language temporal resolution ("what did I drive
  before this one") and multi-hop temporal reasoning are out of scope.
- **No system-initiated invalidation.** Consolidation cannot retire a
  `:kept` fact; it can only propose the retirement.
- **No role-only collection and no Search-to-Memory promotion.** A verified
  principal and the Memory-specific collection policy are required.
- **No ungrounded field in a consolidation-produced conversation proposal.**
  Assistant context resolves only to operator-authored spans; explicit writes,
  manual imports, and legacy drafts use their typed action/digest provenance.
- **No deletion of legacy public shapes in v1.3.** Absorption keeps them
  responding; removal is a later Tier-2 decision.
- **Forget does not delete conversations.** The originating message stays
  canonical and searchable, and the disclosure says so.
- **No automatic conflict winner.** Recorded time orders evidence; it does not
  decide whether a newer statement is true, a correction, or a world change.
- **Additive-only schema** (operator-locked for 1.2–1.4): new
  columns/statuses/tables only; the migration runner stays on the 1.5/1.6
  train.
- Secrets and sensitive content are filtered at proposal time, redacted
  in run summaries, and never bulk-accepted silently (filter hits are
  surfaced as counts, not content).

## Validation

Gate-bound behavioral rows (v1.3 request flow §J and plan M1/M8):
proposed-never-in-prompt,
secret-filter drop, proposal-only managed permission, review-boundary
write-path, kept-only retrieval, zero-egress consolidation, kill-switch
no-op — plus, from the 2026-07-28 amendment: superseded-never-retrieved,
assistant-turn-is-not-a-fact, abstention, and as-of retrieval integrity.
The second readiness amendment additionally requires principal-spoof denial,
collection-class and E2EE opt-in rows, protected-proposal Keep-All denial,
stale-review re-authorization, hash-chain tamper quarantine, legacy-revision
lazy upgrade, manual-append quarantine followed by exact-revision confirmed
import, archive/restore, one origin-scoped grant without per-run/per-DM prompts,
and consumer-grant-specific revocation. Review crash injection covers `applying`,
canonical append, and terminal reduction without duplicate claims. Forget crash
injection covers tombstone-first denial, every cleanup phase, idempotent retry,
bounded canonical read-through, and honest logical-versus-forensic deletion
results without same-predicate overblocking. Portability validation proves
same-Home restore with the original tombstone/key, destination-Home exact-
whole-chain re-confirmation without key export, redacted-envelope exclusion, and
fail-closed copied tombstones with a missing/mismatched key. Legacy validation
proves the actual discovery producer emits no new memory drafts while one
exact-digest confirmed existing draft reaches the authoritative claim writer.

The final readiness contracts add focused rows for:

- fabricated but correctly hash-chained native transitions, which quarantine
  without a valid native-domain tag; first-write key provisioning, master-key
  rewrap with unchanged material, referenced-version retention, and missing-key
  write denial;
- two distinct concurrent appends from one tail, which produce one commit and
  one typed stale-tail result without lost content, plus crash injection before
  file sync, rename, and directory sync;
- deterministic legacy ids, pre-adoption rename semantics, signed first
  adoption, duplicate embedded-id quarantine, and value-bound suppression after
  a copied/renamed legacy file;
- exact external-message thread-ref/principal evidence, verified local-message
  eligibility without a provider ref, identity remap denial, deterministic safe
  backfill, and ambiguous legacy rows excluded from both consumers;
- startup with pending tombstones and applying proposal/draft rows, proving
  suppression is installed first, tombstone cleanup precedes append recovery,
  paused Jobs remains fail-closed, and explicit repair is idempotent;
- successful and crash-interrupted legacy-draft promotion, proving the YAML
  payload and artifact are scrubbed and a concurrent/later Forget cannot be
  resurrected by recovery;
- tombstones and durable confirmation/audit summaries containing only the
  closed reason code and no free-form explanation; and
- canonical message/thread deletion with a changed reference-row cascade,
  same-confirmation crash retry, fresh absent target, Search reconciliation,
  preserved cross-domain records, and exact retained-copy disclosure.

The Accepted flip requires the full propose→review→retrieve chain proven
end to end, the measured zero-shot corpus result (uplift, token delta,
**and** the abstention rows) recorded in the v1.3 plan's Build Progress,
and one full supersession cycle proven: fact kept → contradicting
statement → supersession proposed → operator review → the retired fact
absent from retrieved context while still present and auditable on disk.
