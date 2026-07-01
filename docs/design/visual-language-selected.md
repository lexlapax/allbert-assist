# Selected Visual Language — Direction C (Soft Modern Depth)

Status: v0.60b M5 design artifact and v0.61 build input. This document records the
operator's canonical visual-language **choice**, its rubric rationale, the definitive
spec, and the design-system **token/component delta v0.61 must build**. It is design
only: v0.60b adds no runtime authority, no Settings key, no capability. The choice is
also recorded in `docs/adr/0079-visual-design-language-and-art-direction.md`
(Accepted-with-choice (v0.60b)).

## Chosen direction

**Chosen direction: C — Soft Modern Depth** (`docs/design/visual-direction-c.md`).

The operator evaluated the three rendered candidate directions — **Direction A** (Warm
Editorial Calm), **Direction B** (Precise Technical Console), and **Direction C** (Soft
Modern Depth) — side-by-side as real pixels at `/preview/visual/{a,b,c}/*` and
**selected Direction C** as the canonical visual language.

## Rubric rationale (why C)

Scored against the M2 rubric in `docs/design/visual-language-comparison.md` (C: 85
weighted; B: 95; A: 90):

- **Deciding axis — Axis 2 "does it feel 1.0 / ultra-modern" (won by C, score 5).**
  Direction C has the highest 1.0 ceiling and the most distinctive, memorable identity
  of the three: tonal violet depth, rounded geometry, and spatial motion read as the
  most unmistakably modern product.
- **Accepted trade-offs.** C does not lead the weighted total — Direction B (95) is the
  stronger technical-prosumer *persona fit* (Axis 1) and ties for cheapest delta and
  best a11y. The operator deliberately **favored distinctiveness (Axis 2) over the
  rubric-leading total**, accepting C's two costs: (1) the **largest token delta** — it
  adds an elevation/shadow dimension beyond A/B (Axis 3 = 4); and (2) the **a11y /
  discipline burden** — the overshoot motion and depth must stay disciplined and
  collapse cleanly (Axis 4 = 4, verified holding in the v0.60b render check).
- **Not a prose choice.** The selection was made from rendered pixels, and dark mode +
  high-contrast were verified holding (deep violet-charcoal in dark; high-contrast
  forces `#000000`, the guarded color tokens yielding to the a11y axis) before it was
  recorded.

## Canonical visual-language spec

This pins Direction C definitively as the product's visual language (the full facet
spec, wireframes, and per-screen composition live in `visual-direction-c.md`; this is
the canonical summary v0.61 builds to).

- **Identity / character:** soft, dimensional, friendly-but-serious — rounded geometry,
  tonal violet surfaces with gentle elevation, roomy density. Warm and modern without
  becoming a toy.
- **Type:** rounded geometric, system-local — `ui-rounded, "SF Pro Rounded", "Hiragino
  Maru Gothic ProN", "Quicksand", system-ui, sans-serif` (graceful fallback to
  `system-ui`; no web-font fetch).
- **Color:** tonal violet-tinted neutrals; near-white cards lifted off a tinted canvas.
  Light `--allbert-surface-0/1/2 = #f2f1fb / #ffffff / #e8e5f7`; dark `= #14121f /
  #1c1930 / #251f3d`; accent violet `#7c6cf0` (light) / `#a99bf7` (dark).
- **Spacing / density:** roomy — `--allbert-density: 1.1`, with large gaps between the
  floating cards so the depth reads clearly.
- **Motion:** spatial, expressive-but-controlled — `--allbert-motion-duration
  fast/base/slow = 140/200/300ms`, ease `cubic-bezier(0.2, 0.8, 0.2, 1)`, gentle
  emphasis overshoot `cubic-bezier(0.34, 1.4, 0.64, 1)` for card entrance; **must fully
  collapse under `data-reduce-motion`**.
- **Layout / composition:** floating rounded cards on a tonal canvas; content grouped
  into soft elevated panels with generous gaps; large radii
  (`--allbert-radius-panel: 1.25rem`, `--allbert-radius-control: 0.875rem`); depth via
  tonal surfaces **and** a disciplined soft shadow (`--allbert-shadow-panel`).
- **Chat-primary hero:** the conversation sits inside a raised, rounded card floating on
  the tonal canvas with a soft floating composer beneath — the warmest, most
  product-like hero of the three.

## Token / component delta v0.61 must build

The delta extends the v0.58 substrate (ADR 0074) and the
`docs/design/design-system-gap-analysis.md` backlog. v0.60b's `[data-visual-direction="c"]`
CSS override blocks are **disposable exploration**; v0.61 must build the following as
**first-class, reusable tokens/variants/patterns**, not per-page styling:

### Tokens

- **Semantic elevation / depth scale (new — the C-specific addition).** Named depth
  roles (canvas / raised-card / overlay / modal) mapping to tonal surface steps **and**
  the disciplined soft-shadow (`--allbert-shadow-panel` deepened, violet-tinted). This
  is the gap-analysis "Semantic surface-depth scale" gap, which Direction C makes
  load-bearing.
- **Tonal surface-tone hierarchy (extend).** The violet-tinted `--allbert-surface-0/1/2`
  + `--allbert-line` values above, as semantic surface tones (canvas vs card vs muted),
  with the dark-mode tonal set — the gap-analysis "Surface-tone hierarchy" gap.
- **Large-radius scale (extend).** Promote the large radii
  (`--allbert-radius-panel: 1.25rem`, `--allbert-radius-control: 0.875rem`,
  `--allbert-radius-pill`) to first-class scale tokens.
- **Rounded type token (extend).** The rounded geometric `--allbert-font-family` stack
  as the canonical product family, with the type scale/weights from ADR 0074.
- **Motion roles, reduced-motion-gated (new).** Named spatial motion roles (card-enter
  with the emphasis overshoot, route, drawer, modal, status-change) each **gated by
  `data-reduce-motion`** — the gap-analysis "Motion roles" gap, which C makes central.
- **Density scale (extend).** The roomy `--allbert-density: 1.1` posture as a
  first-class compact/default/comfortable density set — the gap-analysis "Density scale"
  gap.

### Component variants & patterns

- **Elevated / floating card variants.** Raised rounded-card variants for panels,
  chat-surface, evidence cards, and choice cards carrying the depth scale — the visible
  signature of Direction C.
- **Chat-primary hero pattern.** The raised conversation-card + floating composer
  composition as a reusable pattern (extends the gap-analysis "first useful chat
  checkpoint pattern").
- **Soft nav-pill variant.** The rounded nav-pill treatment for the grouped-navigation
  variant (extends the gap-analysis "Grouped navigation variant").
- **Trust-posture soft card.** The elevated trust/authority card variant (extends the
  gap-analysis "Trust posture compact card").

All extend the ADR 0074 tokens/variant registry/pattern catalog through the unified
catalog; none replaces the v0.58 substrate or the rendering boundary.

## v0.61 build handoff

- **Sole consumer: v0.61 Presentation Layer Overhaul.** v0.61 implements Direction C
  over the v0.60 IA as the polished primary 1.0 surface, building the token/component
  delta above as reusable design-system extensions (feeding the v0.61 ADR 0074
  amendment). v0.61 does **not** inherit the v0.60b disposable `/preview/visual/*`
  exploration code as its build — it re-implements the chosen language properly.
- **Discipline v0.61 must hold:** build the elevation/depth and motion roles as
  first-class tokens (not per-page shadows); keep the dark / high-contrast /
  reduced-motion axes first-class (the overshoot motion must collapse under
  reduced-motion; depth must yield to high-contrast); keep chat the hero.
- **Downstream unchanged.** v0.62 (packaging), v0.63 (onboarding), v0.64 (RC), and v1.0
  (freeze) are unchanged; v0.60b hands its one output — the chosen visual language +
  this token/component delta — to v0.61 only.
