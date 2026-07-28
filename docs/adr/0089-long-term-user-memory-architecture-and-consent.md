# ADR 0089: Long-Term User Memory Architecture And Consent Boundary

## Status

Proposed (v1.3 planning, 2026-07-24). **Research-gated:** the v1.3 M1
research milestone (`docs/research/long-term-user-memory.md`, produced
during the build per `docs/plans/v1.3-plan.md`) resolves the named
placeholders LD-R1/R2/R4/R5 below and amends this ADR before implementation
milestones consume it; the operator signs the research outcomes at M1.
(LD-R3 was subsumed by §7 at the 2026-07-28 readiness pass.)
Flips Accepted at the v1.3 milestone that proves the full chain —
consolidation → system-proposed review → operator keep → prompt-time
context — together with the proposed-never-in-prompt denial row.

**Amended 2026-07-28 (implementation-readiness pass, operator-signed).**
The pass surveyed the deployed long-term-memory literature and found the
original decision modelled memory as append-only: it handled restatement
(idempotent dedupe) but not contradiction. §7 below adds the bi-temporal
fact lifecycle in response; §2 extends the consent boundary to cover
unmaking a fact; §3 restricts what may originate a fact; §5 adds
abstention to the measured claim; §6 gains FTS decision criteria. LD-R3
is subsumed by §7 and retained only as pruning UX. LD-R1/R2/R4/R5 remain
research-gated and M1 still signs them; M1 is now a confirm-and-calibrate
milestone rather than an open survey.

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
(Settings/Security Central), and ADR 0090 (adaptive usage profiling — the
system-facing sibling that consumes the same usage-history sources in
v1.4).

## Context

The stated goal (backlog, `future-features.md:752-796`): a long-term user
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

## Decision

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
- **LD-R1 (research resolves): the proposal representation** — an
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
  local model if model-assisted extraction is used (LD-R5).
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
- **LD-R2 (research resolves): extraction method** — deterministic
  heuristics first (the TraceIndex pattern-type precedent) with
  local-model-assisted extraction as the bounded second stage, versus
  model-primary. Default posture: deterministic-first, model advisory,
  fail-closed to fewer proposals; the research note must set the measured
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
- **LD-R4 (research resolves): retrieval budget accounting** — byte
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
- **LD-R5 (research resolves): consolidation model usage** — whether
  extraction may call the configured local model, and under which
  fan-out/budget bounds (the v1.1 substrate is available but not
  required).

### 6. Conversation history search (conditional substrate)

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

### 7. Fact lifecycle: bi-temporal, non-destructive supersession

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
  comparison, not a model judgment. Model assistance (LD-R5) may only
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

## Consequences

- Allbert gains durable, operator-curated knowledge of its operator with
  a consent story that strengthens rather than erodes the trust spine:
  the system may propose; only the operator makes memory.
- Every direct answer can start from the right context — the measured
  zero-shot uplift is the flagship's acceptance bar, not an aspiration.
- Retrieval cost stops scaling with corpus size (index-backed candidates)
  — a precondition for consolidation being safe to leave on.
- The v0.47 draft pipeline and explicit "remember" paths are unchanged;
  consolidation is a third producer into the same reviewed store.
- v1.4's profiling reads the same episodic sources and proposes through
  an analogous confirm-first boundary (ADR 0090) — the two releases share
  the propose/review grammar deliberately.

## Non-goals and guardrails

- **No automatic promotion to `:kept`** — bulk-accept is an explicit
  operator act on visible entries; nothing self-promotes. The four ADR
  non-goal anchors stand.
- **No embeddings, no learned ranking, no trained memory artifacts**
  (System Memory Distillation stays parked).
- **No egress**: consolidation reads local stores and may use only the
  configured local model per LD-R5; nothing leaves the machine.
- **No retention or deletion changes** beyond the additive proposal tier
  and the lifecycle fields; pruning stays operator-driven through existing
  surfaces, and supersession retires a fact without deleting it.
- **No inferred temporal queries.** As-of retrieval is an explicit
  parameter; natural-language temporal resolution ("what did I drive
  before this one") and multi-hop temporal reasoning are out of scope.
- **No system-initiated invalidation.** Consolidation cannot retire a
  `:kept` fact; it can only propose the retirement.
- **Additive-only schema** (operator-locked for 1.2–1.4): new
  columns/statuses/tables only; the migration runner stays on the 1.5/1.6
  train.
- Secrets and sensitive content are filtered at proposal time, redacted
  in run summaries, and never bulk-accepted silently (filter hits are
  surfaced as counts, not content).

## Validation

Gate-bound behavioral rows (v1.3 plan §G): proposed-never-in-prompt,
secret-filter drop, consolidation-grants-nothing, review-boundary
write-path, kept-only retrieval, zero-egress consolidation, kill-switch
no-op — plus, from the 2026-07-28 amendment: superseded-never-retrieved,
assistant-turn-is-not-a-fact, abstention, and as-of retrieval integrity.

The Accepted flip requires the full propose→review→retrieve chain proven
end to end, the measured zero-shot corpus result (uplift, token delta,
**and** the abstention rows) recorded in the v1.3 plan's Build Progress,
and one full supersession cycle proven: fact kept → contradicting
statement → supersession proposed → operator review → the retired fact
absent from retrieved context while still present and auditable on disk.
