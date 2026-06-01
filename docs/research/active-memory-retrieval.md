# Active Memory Retrieval — Algorithm Research Note

Status: accepted as the v0.39b deterministic retrieval baseline on
2026-05-28. This note is binding for v0.39b where referenced by
`docs/plans/v0.39b-plan.md`; embedding-backed retrieval remains parked as a
future advisory provider.

## Purpose

Specify the deterministic retrieval algorithm for v0.39b Active Memory. The
v0.21 memory review/retrieval substrate provides reviewed memory entries;
v0.39b splits each eligible entry into bounded byte windows before scoring and
runs a deterministic scoring pass before each direct-answer model reply
to surface top-K `review_status: :kept` windows scoped to
`{thread_id, active_app, identity_namespace}`.

This note captures the algorithm so v0.39b's plan can reference it and so
operators can audit and replay retrieval decisions.

## Design Constraints

1. **Deterministic.** Same query + same memory state + same settings → same
   retrieved chunks, byte-for-byte. Replayable from traces.
2. **Inspectable.** Each retrieved chunk's score breakdown is operator-
   visible in the trace metadata.
3. **No embeddings in v0.39b.** Markdown-first memory stays the inspectable
   source of truth. Embedding-backed retrieval is a future
   `AdvisoryProvider` per ADR 0021 — it can land later as a second provider
   that consumes the same scoring shape.
4. **Bounded.** Top-K chunks (default K=5), each ≤ 2KB. Prevents context
   bloat and provider-cost surprises.
5. **Read-only.** Retrieval never promotes, mutates, or infers memory.

## Scoring Function

For each candidate chunk window with `review_status: :kept` in scope
`{thread_id, active_app, identity_namespace}`:

```
score(chunk, query) =
  recency_decay(chunk.updated_at)
  × thread_affinity_boost(chunk, thread_id)
  × identity_inclusion_boost(chunk, identity_namespace)
  × lexical_match(query, chunk)
```

All factors are deterministic functions of inputs. None depend on randomness,
clock, or external state.

### Factor 1: `recency_decay(updated_at)`

Exponential decay with operator-tunable half-life:

```
recency_decay(t) = 2 ^ (- (now - t) / half_life)
```

- `now` is the request timestamp pinned at request start, not at scoring
  time (so concurrent scorers in the same turn see the same `now`).
- `half_life` from `active_memory.score_weights.recency_half_life_days`
  (default 30 days).
- Floor: chunks older than 10 × half_life are pruned from the candidate set
  rather than scored as ≈ 0 (saves CPU on long-lived memory directories).

### Factor 2: `thread_affinity_boost(chunk, thread_id)`

- 1.0 if the chunk carries the current thread through the v0.21 promotion
  `source_ref`/metadata convention (chunk was written in or promoted from the
  current thread).
- 0.6 if the chunk's normalized `app_id` matches `active_app` (chunk is
  app-scoped but not thread-scoped).
- 0.3 otherwise (general operator memory).

Tunable via flattened settings:

- `active_memory.score_weights.thread_affinity.same_thread`
- `active_memory.score_weights.thread_affinity.same_app`
- `active_memory.score_weights.thread_affinity.general`

Defaults shown above.

### Factor 3: `identity_inclusion_boost(chunk, identity_namespace)`

- 1.5 if `chunk.namespace == identity_namespace` (operator persona / identity
  context — slight upweight because operators explicitly opt in to identity).
- 1.0 otherwise.

Tunable via `active_memory.score_weights.identity_inclusion`. The default
1.5 is a deliberate small boost so identity chunks tend to surface for
identity-relevant queries without dominating.

### Factor 4: `lexical_match(query, chunk)`

Simple term-overlap fraction:

```
query_terms = normalize(query)
chunk_terms = normalize(chunk.body)
lexical_match = |query_terms ∩ chunk_terms| / max(1, |query_terms|)
```

`normalize/1`:

1. case-fold;
2. strip punctuation;
3. tokenize on whitespace;
4. drop stop words from a small reviewed stop-word list shipped under
   `priv/active_memory/stop_words.txt`;
5. drop tokens shorter than 2 chars;
6. dedupe.

Floor: `lexical_match = 0.0` excludes the chunk from the result set entirely
(no point scoring a chunk that shares zero terms with the query).

## Top-K Selection

1. Filter candidates to `review_status: :kept`.
2. Filter candidates by scope `{thread_id, active_app, identity_namespace}`.
   Identity-root entries are treated as system `identity` chunks only when
   they derive or declare `origin: :system`, `namespace: :identity`, and
   `app_id: nil`.
   Neutral/core context means `active_app` is `nil` or `:allbert`; in that
   mode only identity chunks and general chunks are eligible.
3. Split each remaining entry body into deterministic
   `active_memory.chunk_max_bytes` byte windows before scoring. These windows
   are the scored chunks. They are complete bounded chunks, not post-selection
   excerpts, so no ellipsis is appended.
4. Filter candidate chunks by `recency_decay > 0` floor.
5. Filter candidate chunks by `lexical_match > 0`.
6. Compute full score for each remaining candidate chunk.
7. Sort descending by score; **stable sort** on `chunk.id` as tiebreaker so
   determinism is preserved across runs.
8. Take top `active_memory.top_k` (default 5).

## Trace Metadata

Each retrieval emits a `## Active Memory` section in the runtime turn
trace with:

- `query_terms_normalized` — the term list after `normalize/1`.
- `scope` — the `{thread_id, active_app, identity_namespace}` triple.
- `candidate_count_before_filter` — raw candidate count from the v0.21
  retrieval substrate.
- `candidate_count_after_filter` — count after scope + decay + lexical
  filters.
- `retrieved_chunks` — list of `{chunk_id, score, recency_decay,
  thread_affinity, identity_inclusion, lexical_match}`.
- `excluded_chunks_sample` — bounded sample of up to 5 highest-scoring
  candidates that didn't make the top-K, for operator debugging.

The section is placed after `## Intent Candidates` and before
`## Memory Review`. The intent classifier and intent candidate scorer do not
receive raw Active Memory chunks; retrieval runs only after direct-answer
selection and before direct-answer model prompt composition.

## Determinism Test

A test fixture under `apps/allbert_assist/test/fixtures/v0.39b/` will pin a
memory state and a query, then assert the same chunk ids appear in the same
order across runs. This is the v0.39b acceptance gate for the algorithm.

## Why Not Embeddings In v0.39b

- Embedding indexes require background re-indexing on memory writes; v0.21
  memory writes are operator-confirmed and infrequent, so the cost-benefit
  is unclear.
- Embedding models drift across provider versions; deterministic replay
  becomes hard.
- Markdown-first inspectability is a core Allbert principle; opaque
  embedding-scored retrieval is harder to operator-audit.
- The deterministic lexical scorer is sufficient for most "remember this
  preference / surface the right context" cases. Embedding retrieval should
  enter as a v0.46+ advisory provider per ADR 0021 once the deterministic
  baseline is calibrated.

## Future Work (Out Of v0.39b Scope)

These extensions are not implemented in v0.39b. They are reserved for
post-1.0 advisory-provider work per ADR 0021:

- Embedding-backed retrieval as a second `MemoryRetrievalProvider`.
- BM25-style term-weighted scoring with corpus-IDF statistics.
- Cross-thread / cross-app retrieval (see `future-features.md` "Cross-Thread
  / Cross-App Memory Retrieval").
- LLM-based query expansion before retrieval.
- Adaptive top-K based on query length or model context window.
- Recency curves other than exponential decay.
- Operator memory pinning and pin-score boosts, after the memory review/write
  path owns a real `pinned` metadata field.

## References

- ADR 0021 — intent/objective/capability/advisory boundary.
- `docs/plans/v0.21-plan.md` — memory review/retrieval substrate.
- `docs/plans/v0.39b-plan.md` — v0.39b implementation plan.
