# Active Memory Retrieval Contract

Status: current contract. Introduced in v0.39b and revised by v1.3 M5.

Active Memory is a deterministic, read-only retrieval pass for direct-answer
model context. It is intentionally not an advisory provider, embedding index,
memory writer, permission source, or intent-routing input.

## Runtime Boundary

- Runtime-facing invocation uses the registered `retrieve_active_memory`
  action through `AllbertAssist.Actions.Runner.run/3`.
- The action is `:read_only`, `:not_required`, and internal-only.
- `AllbertAssist.Memory.ActiveMemory` is a plain retrieval module behind the
  action boundary.
- Direct-answer model mode invokes retrieval after the direct-answer route is
  selected and before model prompt composition.
- If `intent.direct_answer_model_enabled` is false, direct-answer fallback does
  not run Active Memory retrieval.

## Inputs

The action accepts:

- `query`: operator prompt text.
- `user_id`: local memory actor filter.
- `thread_id`: current thread for same-thread affinity.
- `active_app`: active app id for same-app scope and affinity. `nil` and
  `allbert` are neutral/core context.
- `identity_namespace`: defaults to `identity`.
- `valid_at`: optional absolute ISO8601 domain-validity time.
- `known_at`: optional absolute ISO8601 knowledge/recording time.
- `now`: optional ISO8601 timestamp pinned by the caller for deterministic
  recency scoring.

## Candidate Rules

- Prompt-time candidates come only from the complete disposable Memory SQLite
  projection. The legacy `.index.json` artifact is not consulted, and automatic
  retrieval never falls back to a full Markdown scan.
- Only `review_status: :kept` entries are eligible.
- Identity entries are eligible only when they are system-owned identity
  memory: category `:identity`, origin `system`, namespace `identity`, and no
  app id. Manually edited identity files with missing origin/namespace metadata
  default to that system identity shape when parsed.
- General entries have no app id and no namespace, or are explicitly core
  `allbert` general entries.
- Neutral/core context returns identity plus general chunks only.
- App context returns identity, general, and chunks matching the active app.
- Retrieval never reads unreviewed, flagged, or prune-nominated entries.
- Candidate lookup honors explicit `valid_at` and `known_at` axes; an old but
  still-valid kept claim has no implicit recency cutoff.
- Before a selected chunk enters a prompt, the exact projected source path,
  claim id, sequence, digest, current effective state, and Forget tombstone are
  revalidated against canonical Markdown. Invalid, replaced, archived,
  forgotten, corrupt, or symlink-replaced candidates are omitted and queue
  projection repair.

## Scoring

The score follows `docs/research/active-memory-retrieval.md`:

`recency_decay * thread_affinity * identity_inclusion * lexical_match`

Each eligible `Memory.Entry` body is split into deterministic
`active_memory.chunk_max_bytes` byte windows before scoring. These windows are
the returned chunks. They are not post-selection excerpts, so returned chunk
bodies do not append ellipses unless a future contract explicitly changes the
chunking model.

The projection stores deterministic exact-term postings and materializes a
bounded posting slice per query term. Exact lexical hits and stable tie-breaks
are then computed over that bounded union. This keeps high-frequency terms from
forcing a corpus-wide scan while preserving rare multi-term matches.

Settings live under the `active_memory.*` Settings Central fragment and are
safe-write keys:

- `active_memory.enabled`
- `active_memory.top_k`
- `active_memory.chunk_max_bytes`
- `active_memory.score_weights.recency_half_life_days`
- `active_memory.score_weights.thread_affinity.same_thread`
- `active_memory.score_weights.thread_affinity.same_app`
- `active_memory.score_weights.thread_affinity.general`
- `active_memory.score_weights.identity_inclusion`
- `active_memory.internal_candidate_limit`
- `active_memory.excluded_sample_limit`

The returned `chunks` include body text for direct-answer prompt composition.
Action metadata and future trace rendering use `retrieved_chunks`, which omits
chunk bodies and keeps score breakdowns inspectable.

DirectAnswer is the final prompt boundary for text and vision. It caps the sum
of Active Memory chunk bodies at 8,000 UTF-8 bytes, truncates only on grapheme
boundaries, and records `prompt_budget_bytes`, `prompt_bytes`, and
`prompt_truncated?` in body-free trace metadata. Active Memory resolves one
Settings snapshot and one stop-word snapshot per turn.

## Trace And CLI Surfaces

- Runtime traces render `## Active Memory` after `## Intent Candidates` and
  before `## Memory Review` when direct-answer model mode retrieved Active
  Memory.
- The trace section renders chunk ids, paths, scores, score-factor
  breakdowns, scope, normalized query terms, and excluded-candidate samples.
  It also renders prompt-budget metadata and does not render chunk body text.
- `mix allbert.memory list --namespace identity` filters identity namespace
  entries; `--category identity` filters the identity category root.
- `mix allbert.memory retrieve --query "..."` invokes
  `retrieve_active_memory` through the action runner and prints the same
  retrieved chunk ids and score breakdown shape used by trace metadata.
- The packaged twin accepts `--valid-at` and `--known-at`, validates them at the
  CLI boundary, forwards them to the registered action, and prints the
  normalized axes. Surfaces do not call `Claims.as_of/3` directly.
- Consolidation, archive/restore, and Forget remain distinct registered
  mutations. They never live in this read-only retrieval module. Search Central
  is an independent conversation consumer and never supplies Active Memory
  chunks.
