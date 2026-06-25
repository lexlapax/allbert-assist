# ADR 0074: Web Design System And UX Language

Status: Proposed (v0.58).
Date: 2026-06-24
Related: ADR 0023 (workspace canvas/ephemeral substrate — kept), ADR 0024 (live
layout authority / zones — revised by v0.58), ADR 0030 (unified surface catalog +
renderer — extended here to be the boundary for every web page), ADR 0015
(app/surface DSL — kept), ADR 0073 (cross-surface contract — this is its web
expression). Anchors the v0.58 web design-system pillar.
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
3. **Pattern library.** Shared, accessible HEEx patterns for **modal/popover,
   loading/streaming, empty state, and error callout**, each with built-in focus
   management and ARIA. Pages compose patterns; they do not re-implement them.
4. **Catalog is the boundary for all pages.** Every operator page — workspace,
   Jobs, Objectives, and the new Intents / Settings-Models / Surface-Policy panels
   — renders through the unified catalog (ADR 0030) inside **one shared app
   shell** (navigation, header/switchers, mobile shellbar). Hand-rolled per-page
   HEEx is removed; Jobs and Objectives are folded into the catalog/shell.
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
- The three v0.58 operator panels and any future app UI extend a consistent
  system instead of adding bespoke pages.
- A documented UX language gives the platform a stable web contract to freeze at
  v1.0, and a conformance target for the v0.59 hardening pass.
- This ADR supersedes the narrow "re-skin only" framing of the prior v0.58 plan
  while keeping all of its concrete moves (chat-primary, modal ephemerals, canvas
  demotion, Conversations relabel, the v0.56 DTO panels, the surface-policy layer).
