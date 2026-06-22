# ADR 0071: Intent Routing-Accuracy Evaluation Harness And Promotion Gate

Status: Proposed (v0.56; accept at v0.56 closeout).
Date: 2026-06-22
Related: ADR 0060 (two-stage intent router + approval-gate separation), ADR 0061
(local embedding + router model tiers), ADR 0062 (intent descriptor lifecycle —
generation, curation, reindex), ADR 0072 (recommended model profiles per
purpose), ADR 0047 (provider doctor contract), ADR 0049 (development gates and
test parallelization).

## Context

ADR 0062 lets descriptors be generated (heuristic in v0.54, local-model in v0.56)
and learned-mined, then promoted into active routing. ADR 0062's own audit found
that only **12 of ~47 routable actions** have descriptors today; v0.56 generates
and curates descriptors for the remaining domains (email, calendar, memory,
image-gen, channels, settings/model, skills/plugin authoring, MCP, objectives).
Adding ~35 new routing targets through a local model and a learned-mining loop is
the largest routing-behavior change since the two-stage router shipped.

The existing intent test surface (the `golden_set_test.exs` structural guard, the
live `mix allbert.intent bench` replay, and the `:v054` authority evals) proves
**authority** ("routing grants nothing", "low confidence clarifies") and provides
a live accuracy number, but nothing **blocks** a descriptor change that makes the
**wrong agent fire**. A generated or learned descriptor can silently regress
routing — steal utterances from a sibling domain, mis-extract slots, execute when
it should clarify, or make a non-routable action (e.g. a v0.55.1 operator
inspection action) reachable — and ship. v0.56 needs a deterministic,
regression-proof guarantee that **the right agent fires**, wired as a gate on
promotion and release, not just a report.

The live `router_local` model is non-deterministic and may be absent in CI, so the
gate cannot depend on it.

## Decision

Introduce an **Intent Routing-Accuracy Evaluation Harness** and make it a
**blocking promotion and release gate**. The harness is advisory infrastructure:
it grants no authority and changes no routing by itself; it only **blocks** a
descriptor promotion or a release when routing accuracy regresses or a
negative-route guarantee breaks.

### 1. Data-only YAML corpus (operator-friendly, versioned)

The labeled routing corpus is **data-only YAML** under
`test/fixtures/intent/eval/<domain>/*.yaml` (mirroring the ADR 0062 descriptor
philosophy: operators edit and diff in an editor, never `.exs`). The shipped v0.54
`anchors.exs` golden set is migrated into this format. One case:

```yaml
schema_version: 1
id: notes-create-001
domain: notes
surface: any            # any | web | tui | telegram | discord | slack | matrix | whatsapp | signal | email
utterance: create a note titled quarterly goals with body grow retention
context: {}
expected:
  kind: execute         # execute | clarify | answer | none
  action: write_note    # required when kind: execute
  slots:                # optional expected slot extractions
    title: quarterly goals
    body: grow retention
negative: false         # true => this utterance must NOT route to `action` (negative-route case)
holdout: false          # holdout cases never tune thresholds
```

The corpus is **seeded by hand** across every routable domain. It is **grown** via a
capture → add → commit flow that keeps CI deterministic:

1. `intent_eval_capture` (action) writes a **redacted** candidate from a real mis-route
   (trace / `doctor` / resolved clarification) to `<ALLBERT_HOME>/intents/eval/captured/`.
2. The operator reviews the candidate.
3. `intent_eval_add` (dev/repo action) promotes a reviewed candidate **into the committed
   fixture** `test/fixtures/intent/eval/<domain>/*.yaml`.

The **committed fixture is the only source the deterministic gate (and CI) reads** —
captures under Allbert Home never affect the gate until added and committed. The corpus
is versioned and diffable in review.

### 2. Two lanes: deterministic gate, live operator bench

- **Deterministic gate (CI, blocking).** A `Runner` replays the corpus through the
  real Stage-1 ranking against a **frozen embedding fixture** and a **fake/seeded
  disambiguator** (existing `FakeEmbedder`/fake disambiguator seams, ADR 0060), so
  the result is reproducible and provider-free. This is the lane in
  `mix allbert.test release.v056`.
- **Live operator bench (advisory).** The existing `mix allbert.intent bench`
  replays the same corpus through the real `router_local` model. Reported, never
  blocking in CI; run by an operator (see ADR 0072 for which model to configure).

### 3. Scorer metrics

`Scorer` computes, over the deterministic run: overall and **per-domain** and
**per-surface** top-1 action accuracy; a confusion matrix (which domain steals
from which); slot-extraction accuracy; clarify-vs-execute correctness (a missing
required slot must clarify, not mis-execute); and **negative-route violations**
(any `negative: true` case that routed, plus the standing guarantee that
`exposure: :internal` / operator-inspection / doctor actions never route — ADR
0062, ADR 0070).

### 4. Gate policy (blocking)

`Gate.check(run, baseline)` fails — blocking the promotion or the release — when:

- overall or any per-domain top-1 accuracy regresses below the recorded
  **baseline** (no-regression rule), **or**
- overall accuracy is below the absolute **floor** (`intent.eval.min_accuracy`,
  default **0.85**) or any per-domain accuracy is below
  `intent.eval.min_per_domain_accuracy` (default **0.80**) — the floor ratchets up but
  never down, **or**
- **any** negative-route violation occurs (zero tolerance), **or**
- slot-extraction accuracy or clarify-vs-execute correctness regresses below
  baseline.

The baseline is a committed, versioned artifact recorded by the `intent_eval_baseline`
action. Both rules apply: no-regression always, plus the ratcheting absolute floor.
Thresholds live in **Settings Central** (`intent.eval.min_accuracy` 0.85,
`intent.eval.min_per_domain_accuracy` 0.80, `intent.eval.block_on_regression` true; all
in `safe_write_keys`); the gate reads them through the schema, never hard-codes them.

### 5. Wiring (promotion + release)

- **Promotion**: `mix allbert.intent promote` and the `optimize_intent_descriptors`
  action run `Gate.check` against a candidate resolved set **before** writing the
  descriptor active; a failing gate rejects the promotion with a diagnostic and
  changes nothing.
- **Release**: `release.v056` runs the deterministic lane; a gate failure fails the
  release.
- **Capture**: `mix allbert.intent eval capture` promotes a **redacted** real
  mis-route (from traces / `doctor` / a resolved clarification) into the corpus,
  so the corpus tracks real drift; capture writes go through the same
  redaction/path-safety rules as the descriptor store.

### 6. Operations are registered actions

Every eval operation is a **registered Jido action** resolved through
`Actions.Runner.run/3`, not Mix-task-local code — so the Mix CLI, the TUI, the v0.58
web panels, and any channel are thin views over one implementation (extends ADR 0070).
Reads (`intent_eval_run`, plus the lifecycle `intent_doctor`/`intent_coverage`/
`intent_list_descriptors`/`intent_list_review`) are `exposure: :internal`,
`permission: :read_only`, absent from `Actions.Registry.agent_modules/0`, and never
intent candidates. Mutations (`intent_eval_baseline`/`capture`/`add`,
`promote_intent_descriptor`, `optimize_intent_descriptors`) are operator-exposed and
audited; the ones that touch routing call the gate helper rather than re-implementing it.

## Authority invariants

- The harness, the corpus, the scorer, and the gate **grant no authority**. They
  observe routing and **block** unsafe promotions/releases; they never execute an
  action, set a `confirmation_id`, lower a safety floor, or make an action
  routable. Security decisions remain at the action boundary (Security Central,
  ADR 0060).
- The gate only ever **prevents** a routing change (fail-closed); it can never
  enable one. A promotion that would pass still goes through ADR 0062 operator
  promotion + audit.
- Corpus capture is redacted and local-only; no raw private payloads, no egress.

## Consequences

- New: `Intent.Eval.{Corpus,Runner,Scorer,Gate}`, a data-only YAML corpus, the
  `mix allbert.intent eval run|baseline|capture|add` subcommands, `:v056`
  routing-accuracy eval rows, the `release.v056` deterministic lane, and
  `intent.eval.*` Settings Central keys.
- Promotion and release now fail closed on routing regression and negative-route
  breaks — the "right agent fires" guarantee for the v0.56 coverage expansion.
- The live bench remains the operator's model-quality signal; its quality depends
  on the configured `router_local` meeting the ADR 0072 recommendation.
- The doctor (ADR 0047 envelope) surfaces corpus size, last baseline, per-domain
  coverage, and gate status.

## Alternatives considered

- **Keep the live bench as the only signal.** Rejected: non-deterministic and
  provider-dependent; cannot be a CI gate.
- **`.exs` corpus.** Rejected: not operator-editable/diffable; violates the ADR
  0062 data-only boundary.
- **Advisory-only reporting.** Rejected for v0.56: the coverage expansion is large
  enough that a non-blocking report would let regressions ship.
- **Absolute floor only (no baseline).** Rejected: a floor alone permits silent
  regression above the floor; no-regression-vs-baseline plus a ratcheting floor
  catches both.
