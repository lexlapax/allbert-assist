# ADR 0089: Long-Term User Memory Architecture And Consent Boundary

## Status

Proposed (v1.3 planning, 2026-07-24). **Research-gated:** the v1.3 M1
research milestone (`docs/research/long-term-user-memory.md`, produced
during the build per `docs/plans/v1.3-plan.md`) resolves the named
placeholders LD-R1–LD-R5 below and amends this ADR before implementation
milestones consume it; the operator signs the research outcomes at M1.
Flips Accepted at the v1.3 milestone that proves the full chain —
consolidation → system-proposed review → operator keep → prompt-time
context — together with the proposed-never-in-prompt denial row.

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
- **LD-R3 (research resolves): durable-fact recency semantics** — LTM
  `:kept` facts must survive the hard staleness floor. Options: a
  floor-exempt durable class, reviewed-at refresh on access, or per-class
  half-lives. Default posture: floor exemption for the LTM class with
  operator-visible pruning through the existing review/prune surfaces.
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
- **No retention or deletion changes** beyond the additive proposal tier;
  pruning stays operator-driven through existing surfaces.
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
no-op. The Accepted flip requires the full propose→review→retrieve chain
proven end to end plus the measured zero-shot corpus result recorded in
the v1.3 plan's Build Progress.
