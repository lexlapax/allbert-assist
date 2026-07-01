# Visual-Language Brief & Evaluation Rubric

Status: v0.60b M2 design artifact and v0.60b M3/M4/M5 input. This document pins the
requirements the visual language MUST satisfy and defines the scored rubric the
operator uses to compare and choose among the M3 candidate directions. It is
**design only**: v0.60b adds no runtime authority, no Settings key, no capability, and
no live provider behavior.

## Purpose

M1 surveyed the ultra-modern bar and produced a mood/direction inventory without
choosing. This brief converts that survey into **must-satisfy requirements** — the
constraints every M3 direction is designed against — and an explicit
**## Evaluation Rubric** the operator scores the ≥3 directions with in M4 and chooses
with in M5 (S4.5). Together they ensure the choice is made against one written
yardstick, not taste alone.

## Must-Satisfy Requirements

Every M3 candidate direction MUST satisfy all six requirement groups below. A
direction that fails any group is not a valid candidate.

### 1. The v0.60 IA / journey / trust surfaces (dress, do not reopen)

The visual language decorates the structure ADR 0077 already fixed; it does not add,
remove, or reorder screens, routes, or the navigation model. Concretely it must dress:

- The five-stage journey from `product-experience-spec.md` (Install, First-run,
  Onboard, First-value, Daily-use) — most directly First-run and First-value, which
  the four hero screens represent.
- The grouped navigation model from `information-architecture.md` (Start / Work /
  Operate / Extend / Trust).
- The four hero screens the M3 renderings must cover: **workspace** (the primary chat
  surface), **onboarding** (the first-run wizard surface), **trust** (the trust/
  authority surface), and **launch** (the landing/start surface).
- Trust affordances as first-class UI (M1 principle 5): provider/model status,
  authority-not-granted posture, and trace availability must read as designed
  surfaces, not afterthoughts, per direction.

### 2. The technical-prosumer persona

Per `persona-model.md` and the product-experience-spec audience definition, the
language must read as **credible, capable, calm** — comfortable with terminals and
provider trade-offs, unwilling to debug a source checkout before seeing value. It must
avoid both failure poles named in M1: **consumer-toy** (novelty motion, playful
over-rounding, hype copy framing) and **enterprise-grey** (flat utilitarian chrome
with no craft, the trap the current v0.60 skeleton falls into).

### 3. Catalog / token extensibility

Every direction must be expressible as a **delta over the v0.58 token scales**
(`--allbert-*` / `--workspace-*` custom properties: surface, accent, type, spacing/
density, motion, radius) and the existing component-variant registry, applied through
the unified catalog inside one app shell (ADR 0030/0073/0074). A direction that
requires abandoning the rendering boundary, hand-rolled per-page markup, or a new
theming mechanism is disqualified. See `docs/design/visual-language-research.md`
("What The v0.58 Substrate Can Express Today") for the concrete token inventory each
direction's delta is measured against.

### 4. The a11y axes (all three, first-class)

Dark, high-contrast, and reduced-motion are each already switchable in the substrate
(`data-theme`, `data-high-contrast`, `data-reduce-motion`) and must each remain
first-class under every direction. A direction that reads well only in one mode (e.g.
a soft-depth treatment that collapses in high-contrast, or a motion character with no
clean reduced-motion fallback) is disqualified, not merely penalized.

### 5. The chat-primary composition

Chat is the primary surface (ADR 0074 §71 / ADR 0077 / M1 principle 1: "chat is the
hero, the chrome is quiet"). Every direction's hero composition for the `workspace`
screen must center the conversation, with navigation and status affordances receding
until needed — not a dashboard-first or utility-grid-first composition.

### 6. Performance / local-first

The aesthetic must render fast on prosumer hardware and must not depend on heavy
assets, web fonts requiring network fetch, or network calls — consistent with
Allbert's local-first posture. Material/translucent depth treatments (Direction
cluster C in the M1 inventory) are permitted only if they remain cheap to render and
do not require runtime blur/compositing beyond what the existing shell already pays
for.

## Evaluation Rubric

The rubric scores each M3 candidate direction on five axes, each **0-5**, with a
stated weight. The **weighted total (0-100)** is the comparative score M4 reports and
M5's operator choice is made against; a direction that scores 0 on any axis
(a disqualifying failure per the must-satisfy requirements above) is excluded from
selection regardless of its weighted total.

| # | Axis | What it measures | Weight | 0 | 3 | 5 |
|---|---|---|---|---|---|---|
| 1 | Fit to IA / journey / persona / trust | Does the direction dress the v0.60 IA and hero screens without implying a structural change; does it read as credible/capable/calm for the technical-prosumer persona; are trust affordances first-class? | 25% | Fights the IA, reads consumer-toy or enterprise-grey, trust affordances are an afterthought. | Dresses the IA correctly; persona register is acceptable; trust affordances present but not distinctive. | Dresses the IA cleanly; persona register is precisely calibrated; trust affordances are a designed, first-class part of the composition. |
| 2 | "Does it feel 1.0 / ultra-modern" | Judged against the M1 reference bar (Cluster 1/2/4): does this read as a serious 2024+ product, not a utility dashboard or a novelty demo? | 25% | Reads as the current utilitarian v0.60 skeleton; no craft signal. | Reads as a competent, current product but unremarkable. | Reads as distinctly modern and confident, on par with the M1 reference bar (Linear/Claude/Warp-tier craft). |
| 3 | Implementability on the token/catalog system | Can the direction be expressed as a `--allbert-*` / `--workspace-*` token-scale delta plus a small, named set of new scale tokens, through the existing catalog/variant registry, with no new rendering mechanism? | 20% | Requires abandoning the catalog boundary or a bespoke theming mechanism. | Expressible as a delta but needs a nontrivial number of new token/variant additions. | Expressible as a small, clean delta over the existing substrate; matches an M1 "token-delta shape" directly. |
| 4 | A11y across dark / high-contrast / reduced-motion | Does the direction hold — remain legible, on-brand, and functionally equivalent — across all three axes without degrading to a different, weaker design? | 20% | Fails or severely degrades in at least one axis. | Holds in all three axes with acceptable but visibly reduced fidelity in one. | Holds fully in all three axes with no perceptible loss of the direction's character. |
| 5 | Performance / local-first | Does the direction avoid heavy assets, network-fetched fonts, and expensive runtime compositing (blur/translucency cost) consistent with local-first rendering on prosumer hardware? | 10% | Requires network assets or materially expensive rendering (e.g. heavy blur across large surfaces). | Local-only assets; some added rendering cost but acceptable. | Local-only, negligible added rendering cost over the current shell. |

**Scoring procedure (used in M4 and re-run at M5/S4.5):**

1. Score each of the ≥3 directions on all five axes using the rendered hero screens
   (`/preview/visual/<direction>/{workspace,onboarding,trust,launch}`) as evidence —
   pixels, not prose.
2. Compute the weighted total: `sum(axis_score * axis_weight) * 20` → a 0-100 scale
   (since axis scores are 0-5 and weights sum to 100%).
3. Record the reasoning and trade-offs behind each score in
   `docs/design/visual-language-comparison.md` (M4), referencing the specific hero
   screen(s) that evidence the score.
4. A direction disqualified under any must-satisfy requirement (Requirements 1-6
   above) is excluded from selection in M5 regardless of its weighted total — the
   rubric ranks eligible directions, it does not override a disqualification.
5. The operator's M5/S4.5 choice must name the **deciding axes** — the ones that
   separated the winner from the runners-up — so the choice traces to a rubric
   rationale, not a bare taste call.

## Handoff To M3 / M4 / M5

- **M3** designs each of the ≥3 directions to satisfy every must-satisfy requirement
  above, drawing from the M1 mood/direction inventory (clusters A/B/C as the
  recommended divergent seeds).
- **M4** scores each rendered direction against the five rubric axes and assembles the
  decision-ready side-by-side in `visual-language-comparison.md`.
- **M5** is where the operator's choice, made against this rubric, is formalized into
  `visual-language-selected.md` and ADR 0079 (Accepted-with-choice).
