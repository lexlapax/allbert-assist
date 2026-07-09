# ADR 0077: Product Experience Design & Information Architecture

Status: Accepted (v0.60).
Date: 2026-06-30
Related: ADR 0074 (web design system & UX language — 0077 owns the IA, navigation,
and screen/workspace-composition redesign that 0074 explicitly deferred as a
"component-contract baseline, not a final UX layout redesign"), ADR 0069 (guided
onboarding flow — the flow is *designed* here and *built* in v0.63), ADR 0075
(user-category settings profiles / personas — the persona model is *designed*
here and *built* in v0.63), ADR 0076 (packaging & unified CLI — the entry-point /
first-invocation UX is *designed* here and *built* in v0.62), ADR 0078
(First-Model Path — decided in the same v0.60 design release this ADR opens),
ADR 0073 (cross-surface contract — the surface spine the redesigned IA composes
over, unchanged), ADR 0006 (Security Central — unchanged). Anchors the v0.60
Product-Experience Design release.

## Context

The v0.60 → v1.0 arc was planned as a strict **linear build-chain**: web UX
polish → packaging → onboarding → release-candidate hardening, each release
sequenced by what the next one technically depends on. That order is correct for
*building*. It is exactly wrong for *designing*, because each release was designed
in build-order, blind to the consumer that should specify it:

- **The presentation/polish release "seated a wizard" that had not been designed.**
  The empty-state and suggested-action affordances (ADR 0074's v0.61 overhaul
  amendment) were sized to host an onboarding flow whose shape, steps, and persona
  model did not exist until the onboarding release — the surface was being built to
  fit a thing nobody had drawn.
- **The packaging release "settled entry points" that onboarding had not validated.**
  The unified CLI and first-invocation surface (ADR 0076) were to be frozen as
  Tier-1 candidates before the onboarding flow that is the primary consumer of
  those entry points had been designed against a real first-run journey.
- **The structural UX redesign was owned by nobody.** ADR 0074 delivered a strong
  token/accessibility *substrate* but was explicit that it is "a component-contract
  baseline, not a final UX layout redesign." v0.60 therefore owns the information
  architecture, navigation model, and screen/workspace composition rules — the
  product-shape decision. v0.61 owns the implementation of that design and the
  concrete all-surface layout-system choice needed to build it; that v0.61 choice
  is an implementation composition decision, not a reopening of the IA.

This matters specifically now because of the v1.0 freeze. The **web is the primary
1.0 product surface** (a native desktop client is post-1.0; the packaged binary
serves the web workspace). v1.0 freezes the presentation contracts — the Tier-2
Surface DSL catalog and the workspace substrate — as stable shapes. A redesign
deferred past v1.0 would freeze today's **operator-utility flat structure** and
then force a **post-1.0 contract break** to fix it. The design-direction inversion
(build-order standing in for design-order) does not just risk rework; with a
freeze at the end of the chain, it *guarantees* rework, on the wrong side of the
freeze.

## Decision

Insert a **design-first release at v0.60** that produces **one unified
product-experience design** for the technical-prosumer 1.0 audience, and have every
downstream release **implement slices of that single design** in the unchanged,
dependency-ordered build sequence. Separate **design** (front-loaded and unified)
from **build** (dependency-ordered and incremental).

v0.60 produces a single coherent design covering the whole journey:

1. **The technical-prosumer journey.** One end-to-end narrative —
   install → first-run → onboard → first-value → daily-use — that the rest of the
   arc is measured against, so no release designs its slice blind to the slices
   on either side of it.
2. **Information architecture, navigation, and screen/workspace composition.** The
   structural redesign ADR 0074 deferred: the IA (what surfaces exist and how they
   relate), the navigation model, and how screens and the workspace compose. This
   is the product-shape decision that previously had no owner; v0.60 owns it.
3. **The onboarding-flow design** — shape, steps, and branch points — handed to
   ADR 0069 to *build* in v0.63.
4. **The persona model** — the user-category model that seeds profile defaults —
   handed to ADR 0075 to *build* in v0.63.
5. **The entry-point / first-invocation UX** — how the unified CLI and packaged
   binary present themselves and first value — handed to ADR 0076 to *build* in
   v0.62.
6. **A navigable walking skeleton** — a thin, clickable expression of the redesigned
   IA and navigation, so the design is validated as a real product shape, not only
   as documents.

The concrete v0.60 M2 artifact is
`docs/design/information-architecture.md`: sitemap, screen inventory, navigation
model, screen/workspace composition rules, and the parser-stable preview-route
manifest consumed by the v0.60 walking skeleton.

Downstream releases implement slices of this one design, in the **unchanged build
order**:

- **v0.61** — the structural UX / IA overhaul (implements §2 over the ADR 0074
  substrate), including the operator-chosen concrete layout system across all nine
  IA surfaces, landing *before* the v1.0 freeze.
- **v0.62** — packaging & entry points (implements §5; ADR 0076).
- **v0.63** — guided onboarding & profiles (implements §3 and §4; ADR 0069 / 0075).
- **v0.64** — product release candidate / hardening.

## Consequences

- **The design-direction inversion is removed**, and with it the rework the
  build-order-as-design-order plan guaranteed: each downstream release now
  implements a slice of a design that already accounts for its neighbors.
- **The structural overhaul (v0.61) lands before the v1.0 freeze**, so the frozen
  presentation contracts (Tier-2 Surface DSL catalog, workspace substrate) freeze
  the *redesigned* shapes rather than the operator-utility flat structure — no
  post-1.0 contract break to fix IA.
- **v0.61 chooses layout without changing v0.60's IA.** v0.60 fixes the surface
  inventory, navigation groups, composition rules, and walking skeleton; v0.61
  renders divergent concrete layout systems for those same nine surfaces, records
  the operator choice, and builds the chosen composition in Direction C.
- **v0.60 ships design artifacts plus a navigable skeleton, and no new authority.**
  It is a design release: the polished surface (v0.61), the packaged entry points
  (v0.62), and the onboarding flow (v0.63) are *built* in their own releases against
  this design, not in v0.60.
- The cost is one inserted release in the arc; the benefit is that the most
  freeze-sensitive decision in the program — the product shape that v1.0 locks — is
  made deliberately and up front instead of emerging from build sequencing.

## Non-goals and guardrails

- **No new authority, capability, or egress.** v0.60 produces design artifacts and
  a thin skeleton; it grants nothing. Security Central, confirmations, and the
  action boundary (ADR 0006 / ADR 0073) are unchanged.
- **v0.60 does not implement the polished product surface** — that is v0.61's
  structural overhaul over the ADR 0074 substrate.
- **v0.60 does not implement onboarding or profiles** — those are built in v0.63
  (ADR 0069 / ADR 0075) against the design produced here.
- **Not a native desktop client.** The web remains the primary 1.0 product surface;
  a native client stays post-1.0 (ADR 0076).

## v0.61b note — navigation presentation revised by ADR 0080

The operator's v0.61 manual validation asked for a consolidation of the shipped
navigation *presentation*: one product sidebar with contextually-expanding
workspace sections (the workspace-local submenu column retires), per-shell top
bars replaced by slim per-view headers, and the workspace tool pane docked
beside chat instead of floating over it. That revision is recorded in
`docs/adr/0080-navigation-consolidation-and-workspace-shell-presentation.md`
(v0.61b). This ADR's structure stands: the surface inventory, the unified
journey, the persona, the trust structure, and the navigation *groups* are
unchanged — ADR 0080 changes how the navigation model presents, not what it
contains.

## Amendment (v1.0 planning, 2026-07-09) — non-developer target, two-tier, web-first

The post-v0.63 product-readiness review retargeted 1.0 from a technical prosumer to a
**non-developer local-first operator**, with three product decisions this ADR now records
(see `roadmap.md` §v1.0 Strategic Frame):

- **Two-tier experience.** A friction-light **consumer default** path is the primary
  first-run product experience; a **prosumer advanced** path (BYOK, custom endpoints, CLI)
  is opt-in. The IA, journey, persona, and trust structure of this ADR stand; the two-tier
  split governs which affordances a fresh non-developer sees first.
- **Web-first surface.** The web workspace plus packaged binary are the 1.0 product
  surface; a native desktop client remains post-1.0. Acceptability for a non-developer
  rests on Allbert running as a **persistent background service** started once — the user
  opens the workspace and never re-runs `serve`.
- **Zero-setup first chat.** The consumer default reaches first chat through guided local
  runtime setup if needed and one-click curated-local-model download, with no manual model
  CLI and no API key (see ADR 0078), matching the one-click-model bar set by local-model
  desktop apps.
