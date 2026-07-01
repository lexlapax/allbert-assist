# Visual-Language Research

Status: v0.60b M1 design artifact and v0.60b M2/M3 input. This document surveys the
"ultra-modern" reference bar, extracts the visual and interaction principles relevant
to a trust-first local assistant, and presents a mood/direction inventory for the
v0.60b candidate directions. It is **design only**: v0.60b adds no runtime authority,
no Settings key, no capability, and no live provider behavior. It is descriptive of
the *bar*, not prescriptive of the *choice* — M2 turns it into the brief + rubric and
M3 turns it into ≥3 concrete directions.

## Purpose

The v0.60 walking skeleton proved the product's **structure** (IA, navigation,
composition) but renders it through an operator-utility-flat shell that reads as
visually utilitarian, not modern. This research studies what makes current AI,
desktop, developer, and local-first products *feel* like 1.0 products, and extracts
the principles a **local-first, trust-first assistant whose primary surface is chat**
should adopt — and, just as important, which modern patterns it must reject because
they undercut trust.

The output is not a single recommendation. It is:

1. A **reference survey** across four clusters, with a per-reference "what makes it
   read as modern" extraction.
2. A set of **visual and interaction principles** distilled from the survey, framed
   for Allbert's constraints.
3. A **mood/direction inventory** — named visual-direction clusters the reference set
   falls into — each with a **trust-first fit note** and a mapping to the v0.58 token
   substrate.

## Method

Inputs reviewed:

- The ultra-modern reference set below (modern AI/assistant products, modern
  desktop/developer tools, local-first AI apps, current design systems).
- `docs/design/product-experience-spec.md` — the technical-prosumer audience, the
  first-useful-chat value moment, and the "product, not debug console" position.
- `docs/design/persona-model.md` and `docs/design/information-architecture.md` — the
  surfaces the visual language must dress.
- `docs/design/design-system-gap-analysis.md` — the v0.61 token/variant/pattern
  backlog the visual language must be expressible within.
- The v0.58 token substrate in `apps/allbert_assist_web/assets/css/app.css` — the
  `--allbert-*` / `--workspace-*` custom properties and the `data-theme` /
  `data-high-contrast` / `data-reduce-motion` accessibility axes — i.e. what the
  tokens can and cannot currently express.

Each reference is read for seven facets: **type system, color/surface treatment,
spacing/density, motion character, elevation/depth, layout/composition philosophy,
and interaction feel.** The survey is descriptive; the fit judgements live in the
inventory.

## What The v0.58 Substrate Can Express Today

Grounding the survey against the real tokens so the inventory stays implementable as
a **delta**, not a rewrite:

| Facet | Existing tokens (illustrative) | Headroom / gap for a modern direction |
|---|---|---|
| Type | `--allbert-font-family`, `--allbert-font-mono`, `--allbert-text-strong/soft` | Family + two weights of emphasis exist; a full type *scale* and rhythm is not first-class (gap-analysis "first-run emphasis scale"). |
| Color / surface | `--allbert-surface-0/1/2`, `--allbert-accent`, `--allbert-accent-soft/contrast`, `--allbert-line`, `--allbert-danger/warn/success` | Three neutral surfaces + one accent + semantic status exist; named semantic surface-*tones* and depth roles are a gap. |
| Spacing / density | `--allbert-density`, spacing scale | A single density knob exists; compact/default/comfortable component density is a gap. |
| Motion | `--allbert-motion-duration-fast/base`, `--allbert-motion-ease-standard` | Duration + easing primitives exist; named semantic motion *roles* are a gap; reduced-motion axis already first-class. |
| Depth / radius | `--allbert-radius`, `--allbert-radius-control`, `--allbert-focus-ring`, `--allbert-border-width` | Radius + focus ring exist; a semantic elevation/depth scale is a gap. |
| A11y axes | `data-theme`, `data-high-contrast`, `data-reduce-motion` | All three axes already switchable — any direction must hold across all three. |

The takeaway: every direction M3 proposes can be reached by **overriding `--allbert-*`
values and adding a small number of scale tokens** through the catalog — no new
rendering mechanism. Directions that would require abandoning this substrate are
out of scope.

## Reference Survey

### Cluster 1 — Modern AI / assistant products

The peer set: the surfaces users compare Allbert against.

| Reference | What makes it read as modern |
|---|---|
| **Claude desktop / web** | Warm, editorial neutral palette; generous line-length and reading rhythm; chat is the hero with minimal surrounding chrome; restrained motion; calm, document-like feel that signals "think here". |
| **ChatGPT (2024+ desktop)** | Near-monochrome surface with a single accent; a very quiet shell so the conversation dominates; compact composer; fast, low-drama transitions; the model output *is* the interface. |
| **Raycast AI** | Command-first, keyboard-native; dense but legible; dark-default with crisp hairline separators; instantaneous feel; power surfaced without clutter. |
| **Perplexity** | Source-forward layout; citation/trust affordances treated as first-class UI, not footnotes; clear separation of answer vs evidence. |
| **Vercel v0 / AI SDK UIs** | Geist type + neutral surfaces; component-catalog cleanliness; the AI surface looks like the rest of a serious product, not a novelty toy. |

**Extraction:** modern AI surfaces make **chat the hero and the chrome quiet**; they
treat **trust/evidence affordances as first-class** (Perplexity); they favor **calm,
low-drama motion**; and they read as **serious products, not toys**. The failure mode
in this cluster is *cloud-service chrome* (upsell rails, account nags, novelty
animation) that Allbert must avoid.

### Cluster 2 — Modern desktop / developer tools

The craft bar for a technical-prosumer audience.

| Reference | What makes it read as modern |
|---|---|
| **Linear** | The reference for "feels 1.0": precise neutral palette, tight type scale, purposeful micro-motion, keyboard-first, ruthless information density that still scans. Depth via subtle elevation, not heavy shadow. |
| **Warp** | A terminal that reads as a product: monospace-forward but with a modern shell, blocks over raw scrollback, restrained accent, honest and legible. |
| **Zed** | Fast, native-feeling, minimal chrome; type and spacing tuned for long sessions; depth through hairlines and tone, not decoration. |
| **Arc** | Soft, rounded, slightly playful depth and color; expressive but risks novelty; shows the "warmer, softer modern" end of the spectrum. |
| **Vercel / Linear dashboards** | Grouped navigation with clear hierarchy; compact status rows; consistent semantic color for state. |

**Extraction:** the developer-tool bar is **precision + density that still scans**,
**purposeful (not decorative) motion**, **depth through tone and hairlines rather than
drop-shadow**, and **keyboard-first interaction**. This cluster maps most directly to
Allbert's technical-prosumer persona. The failure mode is *enterprise-grey utilitarian
flatness* — exactly what the v0.60 skeleton currently reads as.

### Cluster 3 — Local-first AI apps

The closest category peers — local model runners with a trust story.

| Reference | What makes it read as modern (or fails to) |
|---|---|
| **LM Studio** | Dense control surface; local-model status and hardware posture surfaced directly; reads capable but can tip into "config panel" density. |
| **Ollama (app/UI)** | Minimal, calm, almost invisible chrome; the model is the point; local-first framing is quiet and honest. |
| **Jan** | Clean chat-primary layout with a settings/model rail; open-source-product cleanliness; approachable without being toy-like. |
| **Msty** | Warmer, more consumer-friendly take on local chat; shows how far "friendly" can go before it stops reading as a serious operator tool. |
| **GPT4All** | Functional but utilitarian — a useful negative reference for where local-first apps read as "utility, not product." |

**Extraction:** the local-first cluster shows that **model/hardware/trust status wants
to be first-class UI**, that **calm honest framing beats hype**, and that the genre's
default failure is **config-panel density with no product hierarchy**. Allbert's edge
is to keep the local-first trust posture *visible but calm* rather than either hidden
or alarmist.

### Cluster 4 — Current design systems

The token/component vocabularies the directions are expressed in.

| Reference | What makes it read as modern |
|---|---|
| **Radix + shadcn/ui** | Unstyled-primitive + token-driven theming; neutral, accessible defaults; the "serious product baseline" many 2024+ apps share. Maps cleanly to a token-delta model. |
| **Vercel Geist** | Tight neutral scale, one accent, monospace pairing; disciplined restraint; "quiet confidence." |
| **Apple HIG (2024)** | Depth through translucency/material and soft elevation; large-title emphasis scale; motion as spatial continuity. |
| **Material 3** | Tonal surface system, dynamic color, explicit elevation levels; the most formalized surface-tone/elevation vocabulary. |
| **Tailwind / Linear's internal system** | Utility-scale spacing and a constrained palette; density as a first-class, tunable dimension. |

**Extraction:** the systems cluster confirms the mechanism — **theming as tokens
(color, surface tone, elevation, density, motion) over accessible primitives** — and
supplies three distinct surface-treatment philosophies: **flat-neutral (Geist/shadcn)**,
**tonal-elevation (Material 3)**, and **material/translucent depth (Apple HIG)**. These
map directly onto three divergent points in Allbert's design space.

## Extracted Visual & Interaction Principles

Distilled from the survey and framed for a local-first, trust-first, chat-primary
assistant:

1. **Chat is the hero; the chrome is quiet.** The primary composition centers the
   conversation; navigation and status recede until needed. (Claude, ChatGPT, Ollama.)
2. **Calm over urgency.** No dark-pattern urgency, countdowns, or attention-grabbing
   motion. Trust is built by a surface that feels unhurried and honest.
3. **Legibility first.** Type scale, contrast, and reading rhythm are tuned for long
   sessions; density must always still scan. (Linear, Zed.)
4. **Depth through tone and hairlines, not decoration.** Elevation is communicated by
   subtle surface-tone steps and 1px lines before drop-shadow or glass. (Linear,
   Warp.) Heavier material/translucent depth is a *deliberate* direction, not a
   default.
5. **Trust affordances are first-class UI.** Provider/model status, authority-not-
   granted posture, and trace availability are designed surfaces, not afterthoughts.
   (Perplexity's evidence treatment; the local-first cluster's status framing.)
6. **Motion is purposeful and reversible.** Micro-motion clarifies spatial and state
   change; it never performs. Every motion role collapses cleanly under
   `data-reduce-motion`. (Linear, Apple HIG spatial continuity.)
7. **Honest affordances.** Suggestion, confirmed action, disabled/repair, and
   effectful action must be visually distinct — a suggestion must never *look* like a
   granted capability. (Directly serves `no-new-authority-design-only` and the
   gap-analysis suggested-action affordance.)
8. **Keyboard-native, technical-prosumer register.** Credible and capable, not
   consumer-toy and not enterprise-grey. (Raycast, Linear.)
9. **Theme as a token delta.** The aesthetic is expressible as `--allbert-*` overrides
   + a small set of scale tokens over the catalog — never a bespoke per-page rewrite.
10. **A11y is intrinsic, not a mode.** Dark, high-contrast, and reduced-motion each
    remain first-class; a treatment that only works in one axis is disqualified.

### Modern patterns to reject (anti-principles for a trust-first product)

- **Dark-pattern urgency** — countdowns, pulsing CTAs, "act now" motion. Undercuts the
  calm-trust posture.
- **Cloud-service chrome** — upsell rails, account/usage nags, telemetry-forward UI.
  Allbert is local-first; the shell must not imply a hosted service.
- **Novelty motion** — springy, bouncy, or decorative animation that performs rather
  than clarifies. Erodes the "serious operator tool" read and fights reduced-motion.
- **Config-panel-as-product** — the local-first genre's default failure (GPT4All,
  dense LM Studio views): settings sprawl with no product hierarchy.
- **False affordance depth** — heavy glass/translucency used decoratively can obscure
  legibility and state honesty; permitted only where it still passes contrast and
  clearly separates authority states.

## Mood / Direction Inventory

The reference set clusters into named visual directions. This is the **fork space**
M3 draws its ≥3 divergent directions from — presented here as candidates, not a
choice. Each entry names its references, its seven-facet character, its **trust-first
fit note**, and its **token-delta shape** over the v0.58 substrate.

### Direction cluster A — Warm Editorial Calm

- **References:** Claude, Msty (restrained), editorial/reading-first products.
- **Character:** warm neutral palette; humanist type with generous reading rhythm;
  airy density; soft, slow, minimal motion; depth through gentle tone steps;
  chat-as-document hero composition; unhurried interaction feel.
- **Trust-first fit:** *strong.* Calm, legible, honest — directly serves the
  calm-over-urgency and legibility principles; reads as "think here." Risk: can feel
  under-powered for a keyboard-first technical prosumer if taken too soft.
- **Token delta:** warm-neutral `--allbert-surface-*`; humanist `--allbert-font-family`;
  comfortable `--allbert-density`; longer `--allbert-motion-duration-*`; low-contrast
  hairlines.

### Direction cluster B — Precise Technical Console

- **References:** Linear, Warp, Zed, Raycast; Geist type.
- **Character:** precise cool-neutral palette; monospace-forward or mono-paired type;
  compact-but-scannable density; crisp, fast, purposeful micro-motion; depth through
  hairlines and subtle tone; grouped-nav + dense status rows; keyboard-native feel.
- **Trust-first fit:** *strong, best persona match.* Credible and capable; reads as a
  serious operator tool; density serves daily-use scanning. Risk: can tip toward
  enterprise-grey if the accent and warmth are too restrained — must stay "modern
  precise," not "utilitarian flat" (the exact trap the v0.60 skeleton falls into).
- **Token delta:** cool-neutral `--allbert-surface-*`; `--allbert-font-mono`-forward
  pairing; compact `--allbert-density`; fast `--allbert-motion-duration-fast`; tight
  radius; 1px `--allbert-line` separators.

### Direction cluster C — Soft Modern Depth

- **References:** Apple HIG material, Arc, Material 3 tonal elevation.
- **Character:** tonal/translucent surface system; rounded geometry; explicit
  elevation levels; expressive-but-controlled spatial motion; soft depth and material;
  layered chat + rail composition; warmer, more dimensional feel.
- **Trust-first fit:** *moderate — highest reward/risk.* Feels the most "1.0 modern"
  and distinctive, but material/translucent depth must be disciplined to preserve
  contrast, state honesty, and reduced-motion collapse; risks the false-affordance-
  depth and novelty-motion anti-principles if pushed. Strong in dark mode; must be
  proven in high-contrast.
- **Token delta:** tonal `--allbert-surface-0/1/2` with elevation steps; larger
  `--allbert-radius`; new elevation/depth scale tokens; spatial-continuity motion
  roles gated by reduced motion.

### Direction cluster D — Neutral Product Minimalism (baseline reference)

- **References:** shadcn/Radix defaults, Geist, Vercel product surfaces.
- **Character:** near-monochrome neutral, single accent; disciplined restraint; default
  density; quiet, fast motion; flat depth with minimal elevation; component-catalog
  cleanliness.
- **Trust-first fit:** *safe but least differentiated.* A reliable, accessible baseline
  that reads as a serious product with little risk — but risks being "generic 2024
  SaaS." Useful primarily as the **control/reference point** the three divergent
  directions are measured against, or as a fallback, rather than a lead candidate.
- **Token delta:** minimal — closest to the current substrate; single accent, flat
  surfaces, default density.

### Divergence note for M3

Clusters **A (Warm Editorial Calm)**, **B (Precise Technical Console)**, and **C (Soft
Modern Depth)** are the three genuinely *divergent* points — they differ on type
(humanist vs mono-forward vs rounded), color/surface (warm vs cool vs tonal), density
(airy vs compact vs layered), and depth model (tone vs hairline vs material). They are
the recommended seed for M3's ≥3 directions so the operator's choice is a real fork,
not three shades of one idea. Cluster **D** is documented as the neutral baseline/
reference, not counted toward the divergence requirement. Direction ↔ facet naming
(type/color/spacing-density/motion/layout/chat-hero) is deliberately aligned with the
M3 direction-doc structure so each cluster drops directly into a `visual-direction-*`
spec.

## Handoff To M2 / M3

- **M2 (brief + rubric)** consumes the extracted principles and anti-principles as the
  must-satisfy requirements, and the seven-facet framing + a11y axes as rubric axes.
- **M3 (three directions)** consumes the mood/direction inventory: clusters A/B/C are
  the recommended divergent seeds, each already carrying a token-delta shape over the
  v0.58 substrate and a trust-first fit note that M4's comparison scores against the
  rubric.
- This research does **not** choose. It fixes the *bar* and the *fork space*; the
  operator chooses one direction in M5 (S4.5), recorded in ADR 0079.
