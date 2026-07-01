# ADR 0079: Visual Design Language & Art Direction

Status: Proposed (v0.60b). The chosen direction is recorded here at v0.60b M5
(the ADR becomes Accepted-with-choice once the operator selects one canonical
visual language from the rendered candidates).
Date: 2026-06-30
Related: ADR 0077 (Product Experience Design & IA — 0077 designed the *structure*:
the information architecture, navigation, and screen composition; 0079 designs the
*visual language* over that structure), ADR 0074 (web design system & UX language —
0079's chosen language extends the tokens/variant registry/pattern catalog and
feeds the v0.61 ADR 0074 amendment), ADR 0030 (Surface DSL catalog) and ADR 0073
(cross-surface contract — the rendering boundary the visual language styles,
unchanged), ADR 0006 (Security Central — the authority boundary, unchanged).
Anchors the v0.60b Visual Design Language release.

## Context

v0.60 (ADR 0077) fixed a design-direction inversion for **structure**: the
information architecture, navigation model, and screen/workspace composition had
no owning release, so it front-loaded that design and handed the implementers a
navigable walking skeleton. A **parallel inversion remained for the visual
language** — the look-and-feel, visual identity, density and motion character, and
the chat-primary composition — and v0.60 did not close it:

- **v0.58 was explicitly a substrate, not a redesign.** ADR 0074 delivered a
  strong token/variant/pattern foundation but was clear it is "a component-contract
  baseline, not a final UX layout redesign." It settled the *system*, not the
  *aesthetic*.
- **v0.60 designed the structure, but was thin on visual composition.** The IA and
  journey are owned and specified, but per-screen composition was thin and the
  chat-primary re-layout was **asserted more than specified** — the *shape* is
  designed, the *visual craft over that shape* is not.
- **v0.61 is scoped to craft/implement, not to design the visual language.** The
  v0.61 ADR 0074 amendment is a brand / motion / visual-hierarchy craft-and-build
  pass — it *implements* an aesthetic; it does not *choose* one. So the ultra-modern
  visual identity — the actual look-and-feel — was owned by nobody, and v0.61 would
  **craft blind**, inventing the aesthetic as it builds rather than realizing a
  chosen one.

The v0.60 walking skeleton made this visible. Rendered through the current
**operator-utility-flat shell**, the product is structurally sound but visually
utilitarian: the IA is right, but the presentation reads as a tool, not a modern
1.0 product. This is the same freeze-trap that motivated ADR 0077. The **web is the
primary 1.0 surface** (a native desktop client is post-1.0), and v1.0 **freezes the
presentation contracts** (the Tier-2 Surface DSL catalog and workspace substrate).
A visual language chosen implicitly during the v0.61 build — or deferred past the
freeze — would lock today's utilitarian look and then force a post-1.0 contract
break to modernize it. The visual language must be **designed, and chosen, before
v0.61 builds** and the freeze locks it.

## Decision

Insert **v0.60b, a design-first point release** (version 0.60.1, between v0.60 and
v0.61) that **designs the ultra-modern visual/UX design language** the v0.61
overhaul then implements. v0.60b is the *visual*-direction parallel to what ADR 0077
did for *structural* direction: it front-loads the aesthetic decision instead of
letting it emerge from build.

v0.60b **produces at least three divergent candidate visual/UX design directions**,
each **viewable as rendered hero screens**, **evaluates** them against an explicit
rubric, and has the **operator choose one** canonical visual language. The chosen
language is the input v0.61 implements. Concretely:

1. **Research first.** A reference/competitive scan of the modern-tool aesthetic bar
   and a written design brief + evaluation rubric (identity, density, motion
   character, chat-primary composition, accessibility fit, feasibility over the
   ADR 0074 tokens).
2. **At least three divergent directions.** Each direction is a real, rendered
   proposal — the canonical hero-screen set the plan pins (four: workspace,
   onboarding, trust, and the `launch` landing/start surface) styled to that
   direction — not a mood board of adjectives. The directions must genuinely
   diverge, so the choice is between real alternatives.
3. **Comparison and selection.** The directions are evaluated against the rubric and
   the **operator chooses one** canonical direction. The choice, and its rationale
   against the rubric, is recorded in this ADR at v0.60b M5 (Accepted-with-choice).
4. **Styled-skeleton proof.** The chosen language is proven by re-skinning the v0.60
   walking skeleton to the selected direction — a hi-fi visual layer over the
   low-fi structural scaffold — so the language is validated as a rendered product,
   not only as documents.

The v0.60 walking skeleton remains the low-fi **structural** scaffold; v0.60b adds
the hi-fi **visual direction** on top; **v0.61 implements the chosen aesthetic over
the v0.60 IA**. Design (structure in v0.60, visual language in v0.60b) is separated
from build (v0.61), and both are chosen deliberately before the freeze.

## Consequences

- **v0.61 implements a *designed* aesthetic over a *designed* structure**, rather
  than crafting a visual language blind while building. The two design releases
  (v0.60 structure, v0.60b visual language) both land before v0.61.
- **The frozen presentation contracts at v1.0 lock the chosen modern language**,
  not the operator-utility-flat one — no post-1.0 contract break to modernize the
  look, the same freeze-trap ADR 0077 closed for structure.
- **The choice is deliberate and operator-owned**, made from at least three real
  rendered options against a rubric, rather than emerging as a side effect of the
  v0.61 build sequence.
- The cost is **one inserted point release** in the arc (0.60.1; it does not
  renumber v0.61-v0.64) and a set of disposable styled explorations — a small,
  bounded price for owning the most freeze-sensitive presentation decision up front.
- The chosen language **extends ADR 0074** (tokens, variant registry, pattern
  catalog) and feeds the v0.61 ADR 0074 amendment as its specified input.

## Non-goals and guardrails

- **Implements no production surface.** v0.60b produces design artifacts, rendered
  candidate directions, and a re-skinned disposable skeleton; **v0.61 implements the
  production surface** over the chosen language. Any rendered styled variants are
  disposable design exploration behind the preview flag.
- **No new authority, capability, or egress.** v0.60b grants nothing. Security
  Central, confirmations, and the action boundary (ADR 0006 / ADR 0073) are
  unchanged, and the catalog stays the rendering boundary (ADR 0030 / ADR 0074).
- **Not a visual-system rebuild from scratch.** The chosen language extends the
  ADR 0074 tokens and catalog; it does not replace the v0.58 substrate.
- **Not a native desktop client.** The web remains the primary 1.0 surface; a native
  client stays post-1.0 (ADR 0076).
