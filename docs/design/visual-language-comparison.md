# Visual-Language Comparison

Status: v0.60b M4 design artifact and M5 selection input. This document scores the ≥3
candidate directions against the M2 evaluation rubric and assembles a decision-ready
side-by-side so the operator makes an informed M5 choice. It is **comparative, not a
verdict**: it surfaces the strengths, weaknesses, and trade-offs of each direction; the
operator chooses one in M5 (S4.5). Design only — no runtime authority, no Settings key.

Inputs: `docs/design/visual-direction-a.md` / `-b.md` / `-c.md` (the three specs),
their rendered hero screens at `/preview/visual/{a,b,c}/{workspace,onboarding,trust,launch}`,
and the rubric in `docs/design/visual-language-brief.md` (§ Evaluation Rubric). The
pixels are the evidence: each score below references the rendered directions, not the
prose.

The rendered hero screens that evidence these scores are kept for posterity in
[`visual-directions/`](visual-directions/README.md) (a side-by-side table of all three
directions × the four hero screens).

## Rubric recap (from the M2 brief)

Each direction is scored **0-5** per axis; the weighted total is
`sum(axis_score × weight) × 20` on a 0-100 scale. A direction disqualified under any
must-satisfy requirement is excluded from selection regardless of total.

| # | Axis | Weight |
|---|---|---|
| 1 | Fit to IA / journey / persona / trust | 25% |
| 2 | "Does it feel 1.0 / ultra-modern" | 25% |
| 3 | Implementability on the token/catalog system | 20% |
| 4 | A11y across dark / high-contrast / reduced-motion | 20% |
| 5 | Performance / local-first | 10% |

## Side-by-side scores

| Axis (weight) | A — Warm Editorial Calm | B — Precise Technical Console | C — Soft Modern Depth |
|---|---|---|---|
| 1 · Fit to IA/journey/persona/trust (25%) | 4 | 5 | 4 |
| 2 · Feels 1.0 / ultra-modern (25%) | 4 | 4 | 5 |
| 3 · Implementability on token/catalog (20%) | 5 | 5 | 4 |
| 4 · A11y across the three axes (20%) | 5 | 5 | 4 |
| 5 · Performance / local-first (10%) | 5 | 5 | 4 |
| **Weighted total (0-100)** | **90** | **95** | **85** |

Legend: **Direction A** = Warm Editorial Calm; **Direction B** = Precise Technical
Console; **Direction C** = Soft Modern Depth.

All three are eligible: none is disqualified under the six must-satisfy requirements
(each dresses the v0.60 IA without structural change, targets the technical-prosumer
persona, is expressible as a token/catalog delta, holds all three a11y axes as verified
in the S4-era render check, centers chat, and renders locally with no heavy assets).

## Per-axis reasoning and trade-offs

### Axis 1 — Fit to IA / journey / persona / trust (25%)

- **A (4):** Calm, legible, and trust affordances read as reassurance. It dresses the
  IA cleanly and the reading-first posture suits first-run/first-value. **Trade-off:**
  the airy, serif, reading-first register can feel *under-powered* for a keyboard-first
  technical prosumer who wants a dense operator instrument.
- **B (5):** Strongest persona match. The docked console with an always-visible status
  rail keeps provider/model/trace/authority posture permanently in view — trust
  affordances are first-class, not buried — and the compact density serves daily-use
  scanning. Reads "credible, capable, calm." **Trade-off:** if the accent/warmth were
  too restrained it could tip toward enterprise-grey; the rendered indigo keeps it
  modern, but this is the axis to hold.
- **C (4):** Inviting and modern; grouped soft cards parse at a glance and trust cards
  read as reassurance. **Trade-off:** the softness reads less "operator instrument"
  than B for a keyboard-first prosumer, and card-heavy placement spends more vertical
  space per unit of information.

### Axis 2 — Does it feel 1.0 / ultra-modern (25%)

- **A (4):** Distinct editorial-modern (Claude-tier); confident and unlike the current
  utilitarian skeleton. **Trade-off:** serif-forward editorial is a narrower modern
  idiom — striking, but less obviously "product 1.0" than a console or a depth system.
- **B (4):** Linear/Warp/Zed-tier console craft; the clearest departure from the v0.60
  utilitarian shell and unmistakably a serious modern tool. **Trade-off:** monospace-
  everywhere is a strong, opinionated signal that some will read as "developer utility"
  rather than "polished 1.0 consumer-grade product."
- **C (5):** Highest ceiling — tonal violet depth, rounded geometry, and spatial motion
  are the most distinctly "1.0 modern" and the most memorable. **Trade-off:** also the
  highest risk of tipping into novelty if the depth/motion discipline slips.

### Axis 3 — Implementability on the token/catalog system (20%)

- **A (5):** Clean, small `--allbert-*` delta (serif family, radius, density, motion,
  warm palette); matches the M1 token-delta shape directly. No new mechanism.
- **B (5):** Equally clean and the cheapest delta (mono family, tight radius, compact
  density, cool palette). No new catalog atom.
- **C (4):** Small delta but adds an **elevation/shadow dimension** (`--allbert-shadow-
  panel`, larger radii, emphasis-overshoot easing) beyond A/B — still within the token
  system, but the largest of the three deltas and the one that most tempts per-page
  shadow tuning in v0.61.

### Axis 4 — A11y across dark / high-contrast / reduced-motion (20%)

- **A (5):** Holds fully — verified in the render check: dark keeps the warmth, colors
  yield to the high-contrast axis, motion collapses under reduced-motion.
- **B (5):** Holds fully — cool dark palette, high-contrast wins, crisp motion collapses
  cleanly.
- **C (4):** Holds **when disciplined** — dark mode is strong (verified deep violet-
  charcoal with high-contrast forcing `#000000`), but the overshoot entrance motion and
  the depth/translucency are the elements most dependent on the reduced-motion collapse
  and contrast guards. It passes, but it is the axis to watch at S4.5.

### Axis 5 — Performance / local-first (10%)

- **A (5):** System-local serif, no heavy assets, no blur — negligible cost.
- **B (5):** System-local mono, flat depth — the cheapest to render.
- **C (4):** System-local rounded font plus one soft box-shadow per elevated card;
  cheap and blur-free, but a small added cost over A/B.

## Reading the result

- **B (95)** leads on the weighted rubric: it is the strongest technical-prosumer fit,
  ties for cheapest/cleanest implementation and best a11y, and its main risk (reading
  cold) is mitigated in the rendered version. It is the **rubric-recommended** default.
- **A (90)** is close behind: the safest, calmest, most legible option, strongest where
  "reassurance and readability" outweigh "operator density." Choose A if the product
  should feel like a calm reading environment first.
- **C (85)** has the **highest ceiling on "feels 1.0"** and the most distinctive
  identity, at the cost of the largest delta and the a11y/discipline risk. Choose C for
  maximum modern distinctiveness if the team accepts the depth/motion discipline burden
  v0.61 must carry.

The scores rank eligible directions; they do not make the choice. The deciding axes to
weigh in M5/S4.5 are **Axis 1 (persona fit)** vs **Axis 2 (feels 1.0)**: B wins Axis 1,
C wins Axis 2, A splits the difference. The operator records the chosen direction and
the deciding axes in M5.

## Handoff to M5

M5 consumes this comparison and the operator's recorded choice to write
`visual-language-selected.md` and move ADR 0079 to Accepted-with-choice (v0.60b),
naming the single chosen direction, its rubric rationale (the deciding axes above), and
the token/component delta v0.61 must build.
