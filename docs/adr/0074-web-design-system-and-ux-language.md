# ADR 0074: Web Design System And UX Language

Status: Accepted (v0.58). M13 + the M13.1 design-system remediation rounds are
implemented and M14 manual operator validation passed (2026-06-25).
Date: 2026-06-24
Related: ADR 0023 (workspace canvas/ephemeral substrate — kept), ADR 0024 (live
layout authority / zones — revised by v0.58), ADR 0030 (unified surface catalog +
renderer — extended here to be the boundary for every web page), ADR 0015
(app/surface DSL — kept), ADR 0073 (cross-surface contract — this is its web
expression), ADR 0077 (Product Experience Design & IA — designs the v0.60
redesign this system is built under, implemented in the v0.61 overhaul).
Anchors the v0.58 web design-system pillar.
Rationale source: the v0.58 rescope web-UX survey (2026-06-24).

## Context

The web app has the bones of a design system but not a coherent one. The v0.58
survey found:

- A **component catalog** (ADR 0030; ~54 registered atoms as of 2026-06-24, the
  count is not load-bearing) and a declarative workspace tree
  exist, and the workspace renders entirely through the catalog. **Color tokens**
  (CSS custom properties), dark mode, and accessibility semantics
  (`role=dialog`/`aria-modal`/FocusTrap, high-contrast, reduced-motion) exist —
  but scoped to `#workspace-shell`.
- **Jobs and Objectives LiveViews bypass the catalog entirely** — hand-rolled
  HEEx with their own layout, spacing, status rendering, and no FocusTrap or
  reduced-motion. They are architecturally discontinuous from the workspace.
- There is **no type or spacing scale** (font sizes and paddings are hardcoded
  per component), **no prop-driven component-variant registry** (button/status/
  card variants are selected by CSS class, not by a declared `variant` prop), and
  **no shared pattern library** — modals, loading/streaming, empty states, and
  error callouts are re-built per page.
- There is **no documented UX language** (terminology, spacing/type scale,
  interaction patterns); copy and labeling vary per page.

v0.58 adds three operator panels (Intents, Settings/Models, Surface Policy) and a
chat-primary re-layout. Without a real system these would add more bespoke pages.

## Decision

Establish a **web design system and a documented UX language**, and make the
component catalog the rendering boundary for **every** web page.

1. **Design tokens.** A documented token set — color, **typographic scale**,
   **spacing scale**, radius/border, and **motion scale** — as CSS custom
   properties, applied globally (not scoped to `#workspace-shell`). High-contrast
   and reduced-motion apply to all pages. Component CSS consumes tokens; no
   hardcoded sizes.
2. **Component-variant registry.** Components declare variants by **prop**
   (`variant: :primary | :secondary | :danger`, status tones, card kinds), not by
   ad-hoc CSS class. The registry is the single source of variant truth, rendered
   through the catalog.
3. **Pattern library.** Shared, accessible HEEx patterns start with the v0.58
   acceptance baseline: modal/popover semantics, empty-state catalog atoms, the
   drawer shell contract, variant-controlled buttons/status affordances, shared
   loading state, status/error callouts, and table/list primitives. Pages compose
   these patterns; they do not re-implement them. This is a component-contract
   baseline, not a final UX layout redesign. That deferred final UX layout
   redesign is now owned by ADR 0077 (Product Experience Design & Information
   Architecture) — designed in the v0.60 Product Experience Design release and
   built on this design system in the v0.61 Presentation Layer Overhaul.
4. **Catalog is the boundary for all pages.** Every operator page — `/`,
   workspace, Jobs, Objectives, and the new Intents / Settings-Models /
   Surface-Policy panels — renders through the unified catalog (ADR 0030) inside
   **one shared app shell** (navigation, header/switchers, mobile shellbar), or an
   ADR-accepted thin landing shape that still emits the shell data contract,
   consumes tokens, and uses the variant registry. Hand-rolled per-page HEEx is
   removed or explicitly deferred; Jobs and Objectives are folded into the
   catalog/shell.
5. **UX language doc.** A maintained guide: terminology (incl. the v0.58
   "Conversations" relabel — UI strings only, no internal rename), the spacing/
   type scales, the variant and pattern catalogs, accessibility requirements, and
   copy conventions. New panels and apps conform to it.

The chat-primary re-layout (chat as the primary surface, ephemerals as modals,
canvas demoted to a launcher/drawer, "Conversations" relabel) is executed **on**
this system, not as a separate one-off re-skin.

## Non-goals and guardrails

- **No model-generated UI.** The catalog remains the rendering boundary
  (ADR 0023 §9 / ADR 0015); the design system does not introduce a path for
  model- or data-generated markup.
- **No substrate rebuild.** Canvas, tiles, ephemerals, Fragment/HMAC, and
  persistence (ADR 0023) are unchanged; this is a system + re-layout, not a
  rebuild.
- **No new routes / no new authority.** `/workspace` stays canonical; launcher
  selection stays view-only; panels render registered-action DTOs (ADR 0073) and
  grant no authority or egress.
- **No internal rename.** "Conversations" is UI-string-only; `Conversations.Thread`
  module/schema/atoms/topics/keys and the volatile `Session.Scratchpad` are
  untouched.

## Consequences

- One token system, one variant registry, one pattern library, one app shell, and
  one rendering boundary (the catalog) for every web page; Jobs/Objectives stop
  being discontinuous.
- M13.1B remediated the `/` home page and remaining raw-button drift before M14.
  `/` is an accepted thin landing page, not full catalog content: it emits the
  operator shell contract, consumes tokens, and uses variant-registry buttons.
  M13.1E added the shared loading/error/status/drawer/table-list pattern baseline
  and routed obvious page-local copies through it without redesigning layout.
- The three v0.58 operator panels and any future app UI extend a consistent
  system instead of adding bespoke pages.
- A documented UX language gives the platform a stable web contract to freeze at
  v1.0, and a conformance target for the v0.59 hardening pass.
- This ADR supersedes the narrow "re-skin only" framing of the prior v0.58 plan
  while keeping all of its concrete moves (chat-primary, modal ephemerals, canvas
  demotion, Conversations relabel, the v0.56 DTO panels, the surface-policy layer).

## v0.61 Presentation Layer Overhaul amendment

Proposed amendment (v0.61). The v0.58 work delivered a strong token and
accessibility *substrate* under an operator-utility *surface*. The v0.58 maturity
review found the gap: no coherent product motion layer yet, brand identity
effectively absent, a thin landing page, no marketing surface, a flat visual
hierarchy, and `system` dark mode that needs explicit OS-preference validation
across shell/page roots. The v0.61 Presentation Layer Overhaul is not a polish
pass alone: it **implements the v0.60 IA and screen-composition redesign**
(ADR 0077) on top of the 0074 design system, then turns the substrate into a
polished product surface for the technical-prosumer 1.0 audience — without
changing authority or the catalog rendering boundary:

- **Chosen layout system** — v0.61 front-loads a layout exploration, renders
  divergent systems across all nine IA surfaces in Direction C, records the
  operator choice, and commits sanitized screenshots under
  `docs/design/layout-systems/` as the design record. This implements the v0.60 IA
  in a chosen composition; it does not reopen the IA itself.
- **Brand identity** — v0.61 designs candidate logo/wordmark, favicon/app-icon, and
  OG-image directions in the chosen Direction C language, records the operator's
  selected mark in `docs/design/brand-identity-selected.md`, commits all candidate
  and selected renderings under `docs/design/brand/`, then applies the chosen
  logo/wordmark across the shell and a real landing surface while retiring the stock
  framework logo. The build applies a chosen design; it does not silently originate
  brand identity during implementation.
- **Motion layer** — entrance/drawer/skeleton transitions over the existing token
  scales, gated by the reduced-motion axis already in the token system.
- **Visual-hierarchy craft pass** — depth, emphasis, density, and populated
  empty/first-run states across `/workspace`, `/jobs`, `/objectives`, and the
  operator panels, with Channels split into a presentation-only workspace
  destination rather than hidden under Models.
- **Landing/marketing surface** — a real `/` with SEO/OG metadata, replacing the
  ADR-accepted thin-landing exception.
- **Suggested-action affordances** — "what can I do" entry points on empty/first
  workspace views (these also seat the v0.63 onboarding wizard).
- **OS dark-mode resolution** so `system` honors the OS preference for app tokens.

Guardrails unchanged: no model-generated UI, no internal rename, no route sprawl
beyond the rebuilt `/` landing and explicit `/objectives` index route, no
standalone settings/models/channels/trust/onboarding routes, the catalog stays the
rendering boundary (ADR 0030), and authority is untouched. This amendment is the
web-design-system contract that freezes (with its additive-only carve-out) at v1.0.

The concrete v0.60 M7 amendment input is
`docs/design/design-system-gap-analysis.md`: token, component-variant, and pattern
gaps mapped to the M2 composition rules / M6 skeleton screens and owned by the
v0.61 Presentation Layer Overhaul.
