# Allbert Active Memory And Identity Slot

Status: **stub.** Shipped alongside the v0.39 plan first revision so the
v0.39 onboarding's identity-slot preview step has a real destination.
Filled in during v0.39b M5.

This guide is the operator-facing reference for the identity memory
namespace and Active Memory retrieval. Implementation details live in
`docs/plans/v0.39b-plan.md`; the algorithm spec lives in
`docs/research/active-memory-retrieval.md`.

## Orientation

- `docs/plans/v0.39b-plan.md` — implementation plan.
- `docs/plans/v0.39b-request-flow.md` — request flow and security evals.
- `docs/research/active-memory-retrieval.md` — deterministic algorithm spec.
- `docs/operator/onboarding.md` — first-run onboarding (v0.39); the
  identity-slot preview step in onboarding points here.

## Identity Slot (Planned, v0.39b)

The optional `identity` memory namespace lets an operator write inert
markdown context (persona, preferences, conversational style, working
boundaries) that Active Memory retrieval can surface before each reply.

- **Location**: `<ALLBERT_HOME>/memory/identity/`. Surfaced as the new
  `:identity` category of `AllbertAssist.Memory` (5th category alongside
  `:notes`, `:preferences`, `:traces`, `:skills`).
- **Authoring shape**: a single `persona.md` or many small files
  (`persona.md`, `style.md`, `boundaries.md`); both work. Each markdown
  file is one `Memory.Entry`. Files under the identity root derive
  `namespace: :identity`, `origin: :system`, and `app_id: nil` unless the
  file contains conflicting metadata, in which case it is not eligible for
  Active Memory until corrected.
- **Write path**: through the existing v0.21 memory review surface (`mix
  allbert.memory review`) after the operator creates or edits local markdown
  files. v0.39b does not add a rich authoring UX.
- **Authority**: identity content is **inert**. It never grants permission,
  never executes, never authorizes an action, and never becomes runtime
  authority. It is operator-edited context only.
- **Namespace ownership**: declared as a **system** memory namespace
  through a new `AllbertAssist.Memory.SystemNamespaces` declarer
  (`origin: :system`, `app_id: nil`). This is distinct from app-owned
  namespaces like StockSage's; `:_system` is not an app id and the v0.27
  app-namespace contract is preserved unchanged.

## Active Memory Retrieval (Planned, v0.39b)

Prerequisite for operator-visible model behavior:
`intent.direct_answer_model_enabled=true` and a usable direct-answer model
profile. Active Memory itself is enabled separately by `active_memory.enabled`.

When `intent.direct_answer_model_enabled` is true, Allbert runs a
deterministic top-K retrieval pass before each direct-answer model call over
`review_status: :kept` memory scoped to
`{thread_id, active_app, identity_namespace}`. The retrieved chunks are added
to the model context as advisory data. Intent ranking and the optional intent
classifier run before Active Memory and do not receive raw retrieved chunks.
When the direct-answer model is disabled, Active Memory is skipped for that
turn.

- **Algorithm**: deterministic recency-weighted lexical scoring. No
  embeddings; no learned ranking; no LLM-driven scoring. Same query +
  same memory state + same settings → same chunks, byte-for-byte.
  Replayable from traces. Full spec in
  `docs/research/active-memory-retrieval.md`.
- **Top-K bound**: `active_memory.top_k` (default `5`).
- **Per-chunk size cap**: `active_memory.chunk_max_bytes` (default
  `2048` bytes).
- **Scope**:
  - **Active app** (e.g., `:stocksage` after a v0.33 handoff): retrieval
    upweights chunks tagged with that app while still surfacing identity
    and general chunks.
  - **Neutral/core** (`active_app: nil` or `:allbert`): retrieval surfaces
    identity + general chunks only. App-tagged chunks for non-active apps
    are excluded so app-private context does not leak into neutral turns.
- **Snapshot rule**: candidate set is snapshotted once per turn.
  Concurrent v0.21 review/update changes during scoring land on the next turn.

## Trace Visibility

Each runtime turn that runs retrieval renders a `## Active Memory` section in
the turn's markdown trace, placed after `## Intent Candidates` and before
`## Memory Review`. The section includes:

- normalized query terms;
- retrieval scope (`thread_id`, `active_app`, identity namespace);
- candidate counts before and after filtering;
- top-K retrieved chunks with per-factor score breakdowns;
- a bounded sample of high-scoring excluded chunks for debugging.

`mix allbert.memory retrieve --query "..."` (new v0.39b helper) prints
the same deterministic top-K for ad-hoc inspection.

## Settings

All `active_memory.*` settings are safe-keys writable through
`update_setting`. Defaults match the v0.39b plan body and the research
note. Score weights are bounded positive numbers; implementation must validate
them as retrieval weights, not as unrelated model-temperature values.

| Key | Default | Notes |
| --- | --- | --- |
| `active_memory.enabled` | `true` | Master switch. Disabling skips the retrieval pass entirely. |
| `active_memory.top_k` | `5` | Top-K bound. |
| `active_memory.chunk_max_bytes` | `2048` | Per-chunk byte cap. |
| `active_memory.score_weights.recency_half_life_days` | `30` | Half-life for exponential decay. |
| `active_memory.score_weights.thread_affinity.same_thread` | `1.0` | Current-thread weight. |
| `active_memory.score_weights.thread_affinity.same_app` | `0.6` | Active-app weight. |
| `active_memory.score_weights.thread_affinity.general` | `0.3` | General-memory weight. |
| `active_memory.score_weights.identity_inclusion` | `1.5` | Boost for identity-namespace chunks. |

## Safety Defaults

- Identity content is **never** treated as authority. Statements that look
  like permissions or instructions in identity files do not change
  Security Central policy, do not enable skills, and do not bypass
  confirmations.
- Active Memory retrieval is **read-only**. It cannot promote, mutate, or
  infer durable memory.
- The retrieval pass is **bounded** by `top_k` and `chunk_max_bytes` so
  the model context does not grow unboundedly.
- No embeddings or vector indexes are used. Embedding-backed retrieval is
  a future advisory provider per ADR 0021, not part of v0.39b.

## What's Not In v0.39b

- No operator-pinning UX and no pin-score boost. Pinning can be added later
  only after the review/write path owns a real `pinned` metadata field.
- No cross-thread or cross-app retrieval (parked under
  "Cross-Thread / Cross-App Memory Retrieval" in `future-features.md`).
- No nightly distillation, personality training, or learned system-memory
  authority (parked under "System Memory Distillation").
- No model-generated identity content; the persona files are
  operator-authored.

## References

- `docs/plans/v0.39b-plan.md`
- `docs/plans/v0.39b-request-flow.md`
- `docs/research/active-memory-retrieval.md`
- `docs/plans/v0.21-plan.md` — memory review/retrieval substrate.
- `docs/plans/v0.27-plan.md` — app memory namespace declaration contract
  that v0.39b extends with a system-namespace declarer.
- ADR 0021 — intent/objective/capability/advisory boundary.
