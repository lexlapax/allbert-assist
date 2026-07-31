# ADR 0094: Knowledge Central And The Derived Wiki Projection

## Status

Proposed (v1.7/v1.8, operator intake closed 2026-07-30 across three rounds).
Binding on the v1.7 Knowledge Stage 1 release and the v1.8 Knowledge Central
flagship. Flips Accepted when the Stage 1 page graph, link and backlink
contract, deterministic lint, edit-divergence promotion, and frozen scale and
latency bounds are green on both packaged hosts.

This ADR does not amend ADR 0002, ADR 0089, or ADR 0092. It declares its
relationship to them below; the corresponding amendments to those documents are
deferred to the milestone that first depends on them, and ADR 0092 must not be
amended while it is the v1.3 release-gating ADR.

## Context

Operators accumulate knowledge in two places Allbert already owns — the
canonical conversation Corpus and the v1.3 markdown claim spine — and in a third
it only reads, the connected document root. None of these is browsable as
compiled knowledge. Memory answers "what is true about the operator" one claim
at a time at prompt-formation. Search answers "where was this discussed" over
conversation history. Neither produces an artifact the operator can open, read,
and navigate.

The LLM-wiki pattern (Karpathy, 2026) proposes compiling knowledge once into an
interlinked markdown page graph rather than re-deriving it per query as RAG
does. Its three layers are immutable sources, generated pages, and a schema; its
three operations are ingest, query, and lint.

Allbert is unusually well positioned for this pattern and unusually badly
positioned for one part of it. The pattern's known failure mode is decay — the
bookkeeping burden of cross-references, staleness, and contradiction exceeds the
value. Its published answer is that an LLM does the bookkeeping tirelessly.
Allbert's v1.3 spine already answers this more strongly: append-only bi-temporal
claims, supersession, operator review, tombstone-first Forget, redaction, and
bounded retention. What Allbert lacks is the cheap part — a page document model
and a link graph. There is no wikilink, backlink, or page-type machinery
anywhere in the codebase, and the existing memory index is a derived
machine-only JSON file, deliberately not a navigable catalog.

The architectural constraint is that this cannot ride the Memory claim spine.
ADR 0089 locks claim origination to verified operator-authored conversation
turns. Wiki pages are synthesized. Reopening that source policy would trade the
security spine of v1.3 for convenience.

## Decision

### 1. Peer subsystem, not a Memory extension

Knowledge Central is a peer consumer of the Corpus, of Memory kept claims, and
of connected document roots — the same Corpus-to-consumer pattern v1.3
established with Search Central. It never originates claims. ADR 0089's source
policy is unchanged and unreopened.

### 2. Pages are a derived projection

Pages are never an authority. Page authorship requires no confirmation, because
nothing durable is authored. The wiki is rebuildable at any time, and deleting
it in full loses nothing.

This is what makes the pattern's economics survive Allbert's confirmation
posture: a fifteen-page ingest is not fifteen reviews.

### 3. Storage split — durable versus derived

| Path | Durability | Contents | Backup |
| --- | --- | --- | --- |
| `<HOME>/knowledge/schema.md` | Durable | Operator-authored schema (ADR 0095) | Included |
| `<HOME>/knowledge/synthesis-cache/` | Durable | Stage 2 cached LLM synthesis | Included |
| `<HOME>/projections/knowledge/` | Derived | Pages, `index.md`, `log.md`, backlink index | Excluded |

`projections/knowledge/` inherits the existing export exclusion for the
`projections/` prefix and its restore-rebuild behaviour without new code.
`<HOME>/knowledge/` is a new durable root and **must be added to export
inclusion** — this is the one portability change the feature requires.

The schema cannot live under `projections/`, which is rebuildable. It does not
live in a connected document root, because Stage 1 requires no document root at
all.

### 4. Editor independence

The wiki is a plain directory of markdown files, readable and editable with any
editor — `vi`, VS Code, TextMate, or a future in-product notes browser.

- Cross-references are **standard relative markdown links**
  (`[RAG](../concepts/rag.md)`), not `[[wikilinks]]`. Relative markdown links
  resolve in every editor and preview surface; wikilinks are a convention of one
  tool family.
- **Backlinks are written into each page as text** by Allbert rather than
  computed by an editor. Backlink navigation therefore works in `vi`, which no
  editor-dependent design can claim.
- No proprietary format, and no editor-specific feature, may be introduced.
- Divergence detection (§6) is filesystem-digest-based, never editor-integrated.

The last two are binding constraints on any future in-product notes editor: the
same directory must render with no migration.

### 5. No fourth database

Stage 1 pages are markdown files; the page and backlink index is derived JSON
beside `index.md`. Knowledge introduces no new SQLite database, so the existing
contract that each of the three databases has one named writer owner is
untouched.

### 6. Operator edits are detected, never overwritten

Each page carries a content digest. A page whose on-disk digest has diverged is
never silently regenerated. Allbert surfaces the divergence and offers exactly
two typed promotion destinations, both existing spines:

- a **claim proposal**, entering the v1.3 review flow; or
- a **note in a connected root**, confirmation-gated per the v0.65 contract.

No third authority concept is introduced. The operator may also discard the edit
or retain it and stop maintaining that page.

This turns the projection's one real cost — pages cannot hold durable operator
edits — into a forcing function: corrections land where they are versioned,
reviewed, and provenance-tracked, and therefore survive the next rebuild. The
surface must state on every page that it is derived and name where to edit
instead.

### 7. Generation lifecycle

Rebuild, purge, and Forget reuse the v1.3 projection generation machinery. A
page cannot outlive the claim or source it derives from. Forget replaces or
retires affected generations exactly as it does for the Memory and Search
projections.

### 8. Synthesis cache (Stage 2)

LLM synthesis output is stored as a durable content-addressed artifact keyed by
`(source_digest, schema_digest, page_type, model_profile_id, prompt_template_version)`.

Rebuild replays cached synthesis; only new or changed sources incur a model
call. This keeps rebuild deterministic, cheap, and zero-egress in the common
case while leaving pages derived.

A schema or model-profile change invalidates the affected keys. The confirming
surface states "invalidates N syntheses, approximately X tokens" before
proceeding. Cache entries are purged on source removal and on Forget of any
contributing claim.

### 9. Composite retrieval facade

A Knowledge query consults its own pages, Memory kept claims, and Search
Central, and labels every fact in the answer with the layer it came from. The
operator asks once and never chooses a tool.

Three properties are binding:

1. **No new authority.** Each layer answers under its own existing
   authorization; the composite concatenates already-authorized results. A fact
   one layer would deny cannot surface because a different layer was asked.
2. **Most-restrictive scope wins.** Mapped-DM scope elevation is requested
   per-layer through the existing Search seam and is never re-implemented in
   Knowledge.
3. **Operator-initiated only.** Knowledge query never enters automatic prompt
   assembly. Memory retrieval remains the sole prompt-time path and the prompt
   budget is unchanged. Knowledge-in-prompt is parked.

Composite latency is bounded by the slowest participating layer and carries its
own frozen bound.

### 10. Ingest trigger and spend

Detection and spend are separated.

- **Detection** of new and changed sources is automatic, deterministic, and
  zero-egress.
- **Ingestion** proceeds automatically only within
  `knowledge.ingest.auto_budget_tokens`. Beyond that budget, sources queue and
  the operator approves a batch whose provider and token estimate are named
  before any egress.
- Setting the budget to zero yields pure staged review; setting it high yields
  continuous background maintenance.

Ingest uses the configured `model_roles.capable` profile. Egress is always named
and estimated before it occurs.

### 11. Feature switch

`knowledge.enabled` defaults to **false**, joining the documented
`search.enabled` true / `memory.consolidation.enabled` false asymmetry wherever
that asymmetry is explained.

### 12. Staging

**Stage 1 (v1.7)** derives the page graph from v1.3 kept claims: page model,
relative-markdown links with written backlinks, `index.md`, deterministic lint,
digest-based edit detection with promotion, workspace tile, and an
`allbert knowledge` CLI group with TUI parity. No documents, no LLM, no egress,
no new source policy, no new permission class, no new database. Stage 1 queries
its own pages only.

**Stage 2 (v1.7)** adds the document ingest substrate, the synthesis cache,
source-summary pages, `log.md`, the operator schema document and its review path
(ADR 0095), LLM-assisted lint, the composite query of §9, budgeted managed
ingestion of §10, and full Web/TUI/CLI/DM surface parity.

## Consequences

- The wiki gains export exclusion, restore-rebuild, Forget generation
  replacement, and one-named-writer semantics for free by being a projection.
- The one real cost — no durable operator edits on pages — is converted into a
  promotion flow that routes corrections to versioned, reviewed storage.
- Rebuild is cheap for Stage 1 (deterministic) and cheap for Stage 2 in the
  common case (cache replay), expensive only when the schema or model changes,
  which is disclosed before it happens.
- A poisoned page is rebuilt away once its source is removed, which is a second
  and independent reason the projection decision is correct (see ADR 0095).
- Three retrieval paths exist after Stage 2, but the operator sees one entry
  point with labelled provenance rather than a choice.
- `<HOME>/knowledge/` is a new durable root requiring an export-inclusion change.

## Non-goals and guardrails

Out of scope, explicitly:

- **Knowledge-in-prompt.** Memory retrieval remains the sole prompt-time path.
- Semantic, embedding, vector, or fuzzy retrieval. Stage 1 and Stage 2 lint and
  query are deterministic or lexical.
- Free-text semantic contradiction detection across documents. Stage 2 is
  narrowed to provenance conflicts on typed fields; general cross-document
  contradiction is parked as noise-prone.
- Multi-user or shared wikis.
- A developer Search-style sidecar document, a generic subsystem manual, or an
  extra milestone plan. One operator guide only.
- Any editor-specific feature, plugin, or format.
- Automatic claim origination from documents. ADR 0089's source policy stands.

## Validation

- Stage 1 deterministic lint rows: contradictions between current kept claims,
  orphan pages, unresolved links, stale pages, under-populated pages.
- Page-graph build and composite-query latency at frozen scale, measured on the
  packaged macOS arm64 and packaged Linux x86_64 hosts, reported separately,
  neither averaged away.
- Edit-divergence rows: a diverged page is never overwritten; each promotion
  destination lands in its own spine.
- Forget rows: Forgetting a contributing claim retires the derived page and
  purges the affected synthesis-cache entries.
- Export and restore rows: `projections/knowledge/` excluded,
  `<HOME>/knowledge/` included, restore rebuilds pages from claims.
- Composite-query rows: authorization is per-layer, scope is most-restrictive,
  and no result appears that its owning layer would deny.
