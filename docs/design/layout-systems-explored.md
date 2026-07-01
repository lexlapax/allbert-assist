# Layout Systems Explored (v0.61 M1)

Status: v0.61 M1 design artifact and M2 selection input. This document specifies the
**four divergent layout systems** the operator evaluates and chooses among in M2
(`CHOSEN_LAYOUT`), each rendered across **all nine IA surfaces** in the operator-chosen
**Direction C (Soft Modern Depth)** visual language. It is **design + disposable
exploration**: v0.61 M1 adds no runtime authority, no Settings key, no capability. The
rendered proof lives behind the `:preview_routes` flag at
`/preview/layout/<system>/<surface>` and reads no business state.

A **layout system** is a composition paradigm — a distinct answer to *where things go*
(the placement of the product shell, primary work canvas, context/utility surfaces, and
the chat-primary hero; the navigation posture; and the responsive spine) — **not** a
restyle. All four are rendered in the same Direction C visual language so the operator
compares *layout*, not aesthetics.

Rendered record: the committed screenshots for every system × surface, plus a
side-by-side composite per surface, are under
[`layout-systems/`](layout-systems/README.md).

## The nine IA surfaces

Every layout system is rendered across all nine v0.60 IA surfaces (from
`information-architecture.md`): **launch**, **onboarding**, **workspace**,
**objectives**, **jobs**, **models**, **channels**, **settings**, **trust**. The five
surfaces v0.60b never wireframed (objectives, jobs, models, channels, settings) get a
real chosen composition here rather than being assumed at build time.

## Mechanism (disposable exploration)

Each system is a `data-layout-system="a|b|c|d"` zone-composition delta on the operator
shell — CSS grid/flow overrides in `assets/css/app.css` scoped to
`.operator-shell[data-layout-system="…"]` — layered with the Direction C
`data-visual-direction="c"` token delta. The same v0.60 walking-skeleton surfaces
render through the catalog under each system (no new catalog atoms, no business-state
reads). This reflows the shared shell markup; it is **not** the M3-M9 build.

## The four layout systems

### System A — "Focused canvas"

- **Paradigm:** a single primary canvas with maximal focus on the chat hero; chrome is
  de-emphasized so the content dominates.
- **Shell / zone composition:** one centered content column (~50rem), generous margins;
  the appbar is present but visually quiet (transparent surface, no card border/shadow).
- **Nav posture:** the standard inline top-appbar nav, de-emphasized.
- **Chat-primary hero treatment:** the workspace conversation is the single centered
  focus; no competing rails.
- **Responsive spine:** the centered column narrows; the appbar collapses to the mobile
  shellbar below the breakpoint.
- **CSS delta:** narrower `.operator-shell-body`, transparent appbar, roomier stack gap.

### System B — "Workbench"

- **Paradigm:** a persistent, dense, operations-forward multi-pane surface; everything
  visible at once.
- **Shell / zone composition:** wide shell (~100rem); the surface's cards flow into a
  **two-column grid** so multiple panes sit side-by-side; tighter shell gaps.
- **Nav posture:** the full top-appbar nav, prominent (opaque card).
- **Chat-primary hero treatment:** chat sits in the primary column with context panes
  beside it, ops-forward rather than focus-forward.
- **Responsive spine:** the two-column node grid collapses to one column on narrow
  viewports.
- **CSS delta:** wide body; `.workspace-renderer` becomes a two-column grid.

### System C — "Progressive shell"

- **Paradigm:** minimal chrome that expands zones on demand; a mobile-first spine scaled
  up to desktop.
- **Shell / zone composition:** a narrow spine (~42rem); the desktop appbar nav is
  hidden and replaced by a full-width, three-column button nav grid (the mobile-shellbar
  posture promoted to desktop).
- **Nav posture:** button-grid navigation, no persistent horizontal appbar nav.
- **Chat-primary hero treatment:** a single focused mobile-style column; chat leads.
- **Responsive spine:** already mobile-first; scales down cleanly with no layout change.
- **CSS delta:** hide `.allbert-appbar-center`, show `.operator-mobile-shellbar` on
  desktop, narrow body.

### System D — "Sidebar-primary"

- **Paradigm:** the conventional, immediately-legible productivity-app shell
  (Linear/Slack/Notion-familiar); lowest learning curve.
- **Shell / zone composition:** a **fixed left sidebar** (brand + vertical nav +
  actions) in a ~15rem column, with a single content pane filling the rest.
- **Nav posture:** a persistent vertical sidebar nav, always visible.
- **Chat-primary hero treatment:** chat fills the content pane to the right of the
  sidebar.
- **Responsive spine:** the sidebar collapses back to a stacked top-appbar + mobile
  shellbar below the breakpoint.
- **CSS delta:** `.operator-shell` becomes a two-column grid (sidebar | content); the
  appbar reflows to a vertical column; the nav becomes a vertical stack.

## Divergence rationale

The four systems occupy genuinely different points in the "where things go" design
space, not three shades of one layout:

- **Nav posture** differs four ways: inline-quiet (A), inline-prominent (B), button-grid
  no-appbar (C), fixed vertical sidebar (D).
- **Primary canvas** differs: narrow single focus (A), wide multi-pane grid (B), narrow
  mobile spine (C), single pane beside a sidebar (D).
- **Chrome weight** differs: minimal/transparent (A), prominent/dense (B), minimal
  expand-on-demand (C), persistent sidebar (D).
- **Density** differs: focus-forward roomy (A), operations-forward dense (B), mobile
  roomy (C), conventional balanced (D).

The choice is a real fork: A optimizes single-task focus, B optimizes at-a-glance
operations, C optimizes minimal-chrome/mobile-continuity, D optimizes familiarity and
navigability. The operator scores them against the v0.60b `visual-language-brief.md`
"does it feel 1.0" rubric in M2 (S4) and records `CHOSEN_LAYOUT`.

## Per-surface composition (all nine surfaces × four systems)

Each system applies its shell/zone paradigm to every surface; the surface supplies its
own catalog composition (from the v0.60 walking skeleton), the system supplies the
zone/nav/chrome placement around it. Per-surface application:

| Surface | A — Focused canvas | B — Workbench | C — Progressive shell | D — Sidebar-primary |
|---|---|---|---|---|
| **launch** | centered landing hero, quiet chrome | wide landing with side info panes | mobile-style landing spine, button nav | landing pane beside the sidebar |
| **onboarding** | single centered wizard column | wizard step + review panes side-by-side | mobile wizard spine, button nav | wizard pane beside the sidebar |
| **workspace** | centered chat hero, minimal rails | chat + context panes in a two-column grid | mobile chat spine, button nav | chat pane beside the sidebar |
| **objectives** | centered objective list | objective cards + activity in two columns | mobile objective spine | objective pane beside the sidebar |
| **jobs** | centered job list | job cards + run history in two columns | mobile job spine | jobs pane beside the sidebar |
| **models** | centered model-readiness column | readiness + policy panes side-by-side | mobile model spine | models pane beside the sidebar |
| **channels** | centered channel list | channel cards + policy in two columns | mobile channel spine | channels pane beside the sidebar |
| **settings** | centered settings column | settings + surface-policy + intents in a grid | mobile settings spine | settings pane beside the sidebar |
| **trust** | centered trust-evidence column | trace + confirmation + approval in a grid | mobile trust spine | trust pane beside the sidebar |

For the disposable M1 previews the surface bodies are the placeholder-only walking-
skeleton compositions; the table records how the chosen system will place each surface's
zones once the build (M4-M5) fills them with real screens.

## Handoff to M2

M2 consumes these four rendered systems and the operator's recorded `CHOSEN_LAYOUT` to
write `layout-systems-selected.md` (the chosen system, the rubric rationale, the
canonical per-surface layout spec for all nine surfaces, and the M3-M9 build handoff).
