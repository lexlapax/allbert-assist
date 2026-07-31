# Allbert Active Memory And Identity Slot

New to Allbert? Start with [Quickstart: Install, Open, Chat](quickstart.md).

Introduced in v0.39b and moved to the single v1.3 Memory projection in M5. The
`workspace:memory` and `allbert admin memory status`
surfaces are first-class over the same substrate (see the
[roadmap](../plans/roadmap.md) and [CHANGELOG](../../CHANGELOG.md) for the current
release line).

This guide is the operator-facing reference for the identity memory
namespace and Active Memory retrieval. Implementation details live in
`docs/plans/archives/v0.39b-plan.md`; the algorithm spec lives in
`docs/research/active-memory-retrieval.md`.

## Orientation

- `docs/plans/archives/v0.39b-plan.md` — implementation plan.
- `docs/plans/archives/v0.39b-request-flow.md` — request flow and security evals.
- `docs/research/active-memory-retrieval.md` — deterministic algorithm spec.
- [Optional onboarding](onboarding.md) — the identity-slot preview step can
  point here after chat is already available.
- `docs/operator/local-knowledge.md` — the v0.65 local files/notes + reviewed
  memory launch-path guide (connect → search/read → confirm write → review → recall).
- `docs/plans/archives/v0.65-plan.md` and `docs/design/local-knowledge-path.md` —
  the local-knowledge product surfaces for reviewed memory.

## Identity Slot

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
- **Write path**: programmatic system entries use
  `AllbertAssist.Memory.upsert_system_entry/1`; operators may also create or
  edit local markdown files and then use the existing v0.21 memory review
  surface (`allbert admin memory review`) to mark them `:kept`. v0.39b does not
  add a rich authoring UX.
- **Authority**: identity content is **inert**. It never grants permission,
  never executes, never authorizes an action, and never becomes runtime
  authority. It is operator-edited context only.
- **Namespace ownership**: declared as a **system** memory namespace
  through a new `AllbertAssist.Memory.SystemNamespaces` declarer
  (`origin: :system`, `app_id: nil`). This is distinct from app-owned
  namespaces like StockSage's; `:_system` is not an app id and the v0.27
  app-namespace contract is preserved unchanged.

## Active Memory Retrieval

Prerequisite for operator-visible model behavior:
`intent.direct_answer_model_enabled=true` and a usable direct-answer model
profile. Active Memory itself is enabled separately by `active_memory.enabled`.
First-run detection writes the direct-answer setting only when
it is absent and a usable provider is selected; an explicit `false` remains
sticky.

When `intent.direct_answer_model_enabled` is true, Allbert runs a
deterministic top-K retrieval pass before each direct-answer model call over
`review_status: :kept` memory scoped to
`{thread_id, active_app, identity_namespace}`. The retrieved chunks are added
to the model context as advisory data. Intent ranking and the optional intent
classifier run before Active Memory and do not receive raw retrieved chunks.
When the direct-answer model is disabled, Active Memory is skipped for that
turn.

Reviewed Active Memory enters the model request as labeled reference data, not
as an instruction. When asked to extract, summarize, acknowledge, or discuss
supplied text, Allbert treats the statements, examples, dates, identifiers, and
preferences in that text as data. An acknowledgment restates the supplied
information; it does not mean Allbert stored it, scheduled anything, sent
anything, or made a future commitment. State changes require an explicit
state-changing request that the runtime resolves through its normal action,
security, and confirmation boundaries.

In v1.3, prompt retrieval reads the rebuildable Memory projection and then
checks each selected result against its exact canonical Markdown claim before
use. A stale archive, update, Forget, corrupt file, or symlink replacement is
omitted and schedules repair; it is never trusted because it was present in the
projection. The old `.index.json` file is no longer a retrieval authority.
`memory.index_enabled=false` still disables legacy Intent memory candidates,
but does not disable Active Memory; use `active_memory.enabled=false` for that.

- **Algorithm**: deterministic recency-weighted lexical scoring. No
  embeddings; no learned ranking; no LLM-driven scoring. Same query +
  same memory state + same settings → same chunks, byte-for-byte.
  Replayable from traces. Full spec in
  `docs/research/active-memory-retrieval.md`.
- **Top-K bound**: `active_memory.top_k` (default `5`).
- **Per-chunk size cap**: `active_memory.chunk_max_bytes` (default
  `2048` bytes).
- **Whole prompt cap**: DirectAnswer admits at most `8000` UTF-8 bytes across
  all selected Active Memory bodies for both text and vision turns.
- **Long files**: eligible memory entries are split into byte-bounded windows
  before scoring. Returned chunks are complete windows, not trimmed excerpts,
  so the body text does not include ellipses added by retrieval.
- **Scope**:
  - **Active app** (e.g., `:stocksage` after a v0.33 handoff): retrieval
    upweights chunks tagged with that app while still surfacing identity
    and general chunks.
  - **Neutral/core** (`active_app: nil` or `:allbert`): retrieval surfaces
    identity + general chunks only. App-tagged chunks for non-active apps
    are excluded so app-private context does not leak into neutral turns.
- **Snapshot rule**: candidate set is snapshotted once per turn.
  Concurrent v0.21 review/update changes during scoring land on the next turn.

## v0.65 Review Surfaces

v0.65 does not change the Active Memory authority model. It adds first-class product
surfaces over the existing review actions:

- `workspace:memory` shows review candidates and dispatches through the Runner.
- Keep maps to `review_memory_entry status=kept`.
- Reject maps to `review_memory_entry status=flagged`; the entry remains non-recallable
  and inspectable.
- Delete dispatches `delete_memory_entry`, remains confirmation-gated, and archives the
  entry rather than hard-deleting it.
- `allbert admin memory status` reports read-only counts by review status for the current
  user/operator by default and prints the scope. Use
  `allbert admin memory status --all-users` for an explicit aggregate across users.

Only `:kept` entries are recallable. `:flagged`, `:prune_nominated`, and `:unreviewed`
entries remain out of direct-answer retrieval.

## Trace Visibility

Each runtime turn that runs retrieval renders a `## Active Memory` section in
the turn's markdown trace, placed after `## Intent Candidates` and before
`## Memory Review`. The section includes:

- normalized query terms;
- retrieval scope (`thread_id`, `active_app`, identity namespace);
- candidate counts before and after filtering;
- top-K retrieved chunks with per-factor score breakdowns;
- a bounded sample of high-scoring excluded chunks for debugging.
- the 8,000-byte prompt budget, admitted bytes, and whether truncation occurred.

`allbert admin memory retrieve --query "..."` prints the same deterministic
top-K for ad-hoc inspection.

Use both explicit temporal axes when validating claim history. `valid-at` asks
what was true at a domain time; `known-at` asks what Allbert had recorded by a
knowledge time. Both must be absolute ISO8601 timestamps:

```sh
allbert admin memory retrieve \
  --query "release call sign" \
  --valid-at 2026-07-01T12:00:00Z \
  --known-at 2026-07-15T12:00:00Z \
  --user local
```

The command prints the normalized axes. Omitted axes default to now. Proposed,
archived, forgotten, corrupt, out-of-time, or canonically mismatched claims are
omitted before prompt insertion.

## Consolidation And Review

The existing recurring Jobs engine owns the weekly `memory-consolidation` job.
Consolidation is disabled by default and reads no source until both the feature
and an origin-scoped collection grant are present:

```sh
allbert admin settings set memory.collection.origin_grants local_operator
allbert admin settings set memory.consolidation.enabled true
allbert admin memory consolidate --user local
allbert admin memory proposals --user local
```

The on-demand command and recurring job call the same registered action.
Consolidation may create only inert, grounded proposals; it cannot keep, edit,
archive, restore, or Forget a claim. It uses the configured local extraction
profile or the deterministic safe subset and never falls back to a hosted
provider. Disable collection without deleting review state:

```sh
allbert admin settings set memory.consolidation.enabled false
```

Inspect a proposal before review:

```sh
allbert admin memory proposal PROPOSAL_ID --user local
```

The proposal output supplies the revision and proposal digest required by the
review command. A Keep or Edit is the authority transition; merely proposing a
fact never makes it retrievable. Batch Keep similarly requires exact per-item
bindings. Review recovery is idempotent if a process stops after the Markdown
append but before the proposal row is scrubbed.

## Archive, Restore, And Forget

Archive is reversible and history-preserving. `delete` remains the compatibility
name; `archive` says what the operation actually does:

```sh
allbert admin memory archive MEMORY_PATH --user local
allbert admin confirmations approve CONFIRMATION_ID --reason "archive reviewed claim"
allbert admin memory restore CLAIM_ID --user local
```

The archive preview prints the claim id and leaves the claim active until
approval. Restore appends a new kept revision through the same canonical claim
writer. If another revision could race the operation, pass the exact current
tail as `--tail-digest` and treat a stale-tail response as a required re-read.

Forget is the separately named destructive operation:

```sh
allbert admin memory forget CLAIM_ID --reason operator_requested --user local
allbert admin confirmations approve CONFIRMATION_ID --reason "forget exact claim"
```

Allowed reason codes are `operator_requested`, `privacy`, `incorrect`, and
`expired`; there is no free-form reason in the tombstone. Forget installs the
content-free suppression tombstone first, then scrubs active claim, proposal,
review, and projection paths. It prevents exact re-proposal and remains
fail-closed across cleanup interruption. It does not promise physical byte
erasure from storage media, backups, exports, or forensic remnants.

Memory Forget also does not delete the originating conversation. That history
remains searchable until the operator uses the separately confirmed canonical
message/thread deletion path described in
[Conversation Search](conversation-search.md#retention-delete-and-purge).

## Quick Smoke

Use this on a disposable `ALLBERT_HOME` or a test identity file to confirm the
operator path before enabling model-backed direct answers:

```sh
mkdir -p "$ALLBERT_HOME/memory/identity"
cat > "$ALLBERT_HOME/memory/identity/persona.md" <<'EOF'
# Persona

I prefer concise release reports with clear validation notes.
EOF
allbert admin memory review "$ALLBERT_HOME/memory/identity/persona.md" --user local --status kept --note "Operator-authored identity"
allbert admin memory retrieve --user local --query "concise release reports"
```

The retrieve command prints chunk ids and score breakdowns only. It does not
write memory and does not print raw memory bodies in trace metadata.

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
| `active_memory.internal_candidate_limit` | `1000` | Internal bounded projection candidate set before chunk scoring. |
| `active_memory.excluded_sample_limit` | `5` | Maximum body-free excluded examples retained for diagnostics. |

## Safety Defaults

- Identity content is **never** treated as authority. Statements that look
  like permissions or instructions in identity files do not change
  Security Central policy, do not enable skills, and do not bypass
  confirmations.
- Reviewed Memory remains reference data even when its prose resembles a
  command. Prompt roles shape the answer but never grant execution authority.
- Active Memory retrieval is **read-only**. It cannot promote, mutate, or
  infer durable memory.
- The retrieval pass is **bounded** by the internal candidate limit, `top_k`,
  `chunk_max_bytes`, and the final 8,000-byte prompt cap so model context does
  not grow unboundedly.
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

- `docs/plans/archives/v0.39b-plan.md`
- `docs/plans/archives/v0.39b-request-flow.md`
- `docs/research/active-memory-retrieval.md`
- `docs/plans/archives/v0.21-plan.md` — memory review/retrieval substrate.
- `docs/plans/archives/v0.27-plan.md` — app memory namespace declaration contract
  that v0.39b extends with a system-namespace declarer.
- ADR 0021 — intent/objective/capability/advisory boundary.
