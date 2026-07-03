# Web Design System

Status: v0.58 shipped the design-system baseline (tokens, variants, shared patterns,
shell, catalog coverage, release lane, M13.1A-G remediation, M14/M15 closeout).
**v0.61 (Presentation Layer Overhaul) shipped the product surface on top of it:** the
v0.60 information architecture and navigation (ADR 0077) implemented in the
operator-chosen **Layout D (Sidebar-primary)** and dressed in the v0.60b-chosen
**Direction C (Soft Modern Depth)** visual language (ADR 0079), plus brand identity,
a motion layer, a real landing/marketing surface, a visual-hierarchy craft pass, and
OS dark-mode resolution. See **v0.61 Presentation Overhaul** below.

Authority: `docs/adr/0074-web-design-system-and-ux-language.md` (v0.61 amendment),
`docs/adr/0077-product-experience-design-and-information-architecture.md`,
`docs/adr/0078-first-model-path.md`,
`docs/adr/0079-visual-design-language-and-art-direction.md`,
`docs/adr/0024-app-ui-contribution-and-workspace-zones.md`,
`docs/design/layout-systems-selected.md`, `docs/design/visual-language-selected.md`,
`docs/design/brand-identity-selected.md`, `docs/plans/v0.61-plan.md`, and
`docs/plans/v0.58-plan.md`.

## v0.61 Presentation Overhaul (Layout D · Direction C)

v0.61 implements the v0.60 product-experience design (IA, navigation, screen
composition) and the v0.60b visual language (Direction C) over the v0.58 substrate,
in the operator-chosen Layout D. It adds no new authority, no new rendering path, and
no route sprawl; every surface still renders through the catalog boundary.

### IA & navigation (ADR 0077, Layout D)

The nine IA surfaces are grouped into five stable nav groups — **Start** (Home,
onboarding affordances), **Work** (Workspace, Objectives), **Operate** (Jobs,
Models), **Extend** (Channels), **Trust** (Settings, Trust). They are presented by a
persistent left **product sidebar** (`Layouts.product_sidebar/1`, a shared component)
carrying the Allbert mark, the grouped icon nav-pills, a primary "New chat" action,
and the sidebar footer (theme toggle + overflow menu — v0.61b M7). **v0.61b update
(ADR 0080):** the sidebar is the ONE navigation home. On `/workspace` its Workspace
entry auto-expands into the contextual workspace sections (Conversations with inline
rename, Output, Apps, Workspace destinations — `WorkspaceSections`); the former
workspace-local submenu column is retired. The sidebar collapses expanded → icon
rail (the Workspace rail entry opens a click-activated flyout) → fully hidden (slim
reopen tab), persisted client-side (`LayoutPrefs`, Cmd/Ctrl+B, Cmd/Ctrl+Shift+B).
Per-shell top bars are retired: each operator view carries a slim
`.operator-view-header` inside the content area, and `/workspace` has exactly one
header band per pane (chat header, pane header). Below the 48rem breakpoint the
sidebar collapses to a bottom mobile shellbar that carries the brand and all nav
pills; the workspace mobile launcher opens the sidebar as an overlay drawer. Active state is route-derived on the operator surfaces and destination-derived
on `/workspace` (`workspace:models → Models`, `workspace:surface_policy → Trust`, …).
Route contract: `/`, `/workspace`, `/jobs`, `/objectives` (index) + `/objectives/:id`
(detail); Models/Channels/Settings/Trust are `/workspace?destination=…` panels, not
standalone routes; there are no `/settings|/models|/channels|/trust|/onboarding`
routes.

### Screen composition (per the v0.60 IA, in Layout D)

Screens recompose through the catalog and variant registry, not per-page HEEx:

- `/workspace` — the chat-primary hero (raised conversation card + floating composer),
  marked `data-workspace-pattern="chat-primary-hero"` on the native chat pane.
- `/jobs`, `/objectives`, `/objectives/:id` — the unchanged `WorkspaceRenderer`
  wrapped in the Direction C `elevated_card` variant (no renderer rebuild).
- Operator panels as workspace destinations — Models (readiness matrix), **Channels**
  (a real action-backed read-only inventory via the `operator_channels` action; the
  earlier static placeholder is retired), Settings Central, and Surface Policy
  (marked `trust-soft-card`).

### Visual language — Direction C, first-class (ADR 0079, `visual-language-selected.md`)

The Direction C token/component delta is promoted into the canonical `:root` /
`[data-theme="dark"]` `--allbert-*` defaults (not a `[data-visual-direction]` preview
override): the semantic elevation/depth scale + violet-tinted `--allbert-shadow-panel`,
tonal `--allbert-surface-0/1/2` + `--allbert-line`, the large-radius scale, the
rounded-geometric `--allbert-font-family`, the density scale, and the reduced-motion-
gated motion roles. Component delta: **two reusable variant components** —
`elevated_card` and the soft `nav_pill` — plus **two Direction C patterns** —
`chat-primary-hero` and `trust-soft-card` — carried as markers on the native chat and
policy surfaces (the native surfaces are richer than 2-zone components).

### Brand identity (`brand-identity-selected.md`)

- Wordmark/mark: `priv/static/images/allbert-mark.svg` (the violet rounded "A" glyph +
  "Allbert" wordmark), applied in the sidebar brand, mobile shellbar brand, and
  landing hero; the stock Phoenix asset is retired.
- Favicon: `priv/static/favicon.ico` (Allbert mark) + the SVG favicon link, so
  browsers without SVG-favicon support (Safari) still show the brand.
- App icon: `priv/static/images/apple-touch-icon.png` (180×180) linked in the root head.
- Social card: `priv/static/images/allbert-og.png` (1200×630, rasterized) referenced
  by `og:image`/`twitter:image`; the SVG remains as a source-of-truth companion.

### Motion layer

Entrance/drawer/skeleton motion runs over the Direction C motion roles built on the
v0.58 motion-scale tokens — `fast/base/slow = 140/200/300ms`, standard ease
`cubic-bezier(0.2,0.8,0.2,1)`, emphasis overshoot `cubic-bezier(0.34,1.4,0.64,1)`.
Durations/easings are token-driven (no hardcoded values); every transition is gated
by the reduced-motion axis (`data-reduce-motion` / `prefers-reduced-motion`) and
collapses to instant when set.

### Visual hierarchy, density, empty/first-run states & affordances

The redesigned surfaces carry Direction C depth (elevated cards, tonal surfaces) and
the density scale. Empty/first-run states are populated from the registry. The
empty-workspace **suggested-action affordances** are shaped by the First-Model Path
(ADR 0078): the empty-handed operator is led with **"Set up your first model"**
(local-first, BYOK alternative), followed by ask-a-question / review-objectives /
check-connections. Each affordance renders a read-only registered-action DTO
(view-only, no authority) and navigates to the real read surface; they seat the v0.63
guided-onboarding wizard along the designed path.

### Landing / SEO / OG

`/` is a real landing/marketing surface composed through the catalog inside the shell
data contract: brand hero, value proposition, feature cards, and variant-registry CTAs
("Open workspace", "Set up a model"), replacing the thin-landing exception. The root
head emits static SEO/OG metadata (title, description, canonical, OG/Twitter card, OG
image) that exposes no operator data or secrets.

### OS dark mode

The `system` theme resolves app tokens to the OS `prefers-color-scheme` across all
shell/page roots (`@media (prefers-color-scheme: dark) [data-theme="system"]`), not a
silent fall-back to light; explicit light/dark overrides still win. The workspace
theme toggle pushes the resolved theme to `<html data-theme>` (the `ThemeSync` hook)
so the sidebar (root) and the workspace shell resolve the same palette. All
theme × high-contrast × reduced-motion × OS-preference cells resolve to a readable
palette (status tokens ≥ AA in system-dark, dark-HC, and prefers-contrast×system-dark).

## Purpose

v0.58 turns the web UI from page-local styling into a reusable design system:
global tokens, prop-driven variants, shared accessible patterns, one app shell,
and the catalog as the rendering boundary for every operator page.

This is not a rebuild of the workspace substrate. ADR 0023, the Surface DSL, the
catalog boundary, and `/workspace` stay in force.

## System Layers

| Layer | Contract |
| --- | --- |
| Tokens | Global CSS custom properties for color, type, spacing, radius, elevation, and motion. |
| Variants | Component variants selected by props, not ad-hoc class strings at call sites. |
| Patterns | v0.58 baseline: shared modal/popover, catalog empty states, drawer shell, variant-controlled controls, loading state, status/error callouts, and table/list primitives. |
| Shell | One app shell: product-sidebar navigation, slim per-view headers, and mobile shellbar (v0.61b — top bars and the thread switcher are retired). |
| Catalog | All operator pages render through validated catalog atoms and fragments. |

Tokens are global, not scoped only to `#workspace-shell`. High contrast and reduced
motion apply to `/workspace`, `/jobs`, `/objectives`, and v0.58 panels.

## Token Contract

Built-in tokens live in `apps/allbert_assist_web/assets/css/app.css` under `:root`,
not under `#workspace-shell`. `#workspace-shell` consumes the same token aliases as
other pages. User theme CSS remains a post-`app.css` override layer so existing
workspace theme files continue to work.

Token families:

- color: surface, text, border, accent, danger, warning, success, info;
- type: family, size scale, weight scale, line-height scale;
- spacing: compact and roomy layout scales;
- radius: control, panel, modal, drawer;
- motion: duration, easing, reduced-motion overrides;
- elevation/focus: shadows, focus rings, active state.

State selectors are global:

- `data-theme="dark"` applies dark-mode tokens.
- `data-high-contrast="true"` and `@media (prefers-contrast: more)` apply contrast
  tokens and thicker focus/border affordances.
- `data-reduce-motion="true"` and `@media (prefers-reduced-motion: reduce)` suppress
  scroll/transition/animation motion.

`Layouts.root` emits the Settings-backed `data-theme`, `data-high-contrast`, and
`data-reduce-motion` attributes so non-workspace pages inherit the design state
before a workspace shell is present. Changed components consume tokens. Do not
introduce page-local color, spacing, type, radius, or motion systems when an
existing token covers the need.

## UX Language

Use consistent operator terms:

- **Workspace**: the canonical operator surface at `/workspace`.
- **Conversations**: UI label for the sidebar Conversations section (the thread
  list; the appbar switcher retired at v0.61b M7); do not rename
  internal `Conversations.Thread`, session, topic, setting, event, or database
  concepts.
- **Canvas**: persistent workspace tiles and app destinations.
- **Ephemeral**: temporary modal/popover work surfaces with explicit dismissal.
- **Operator panels**: Intents, Settings/Models, and Surface-Policy panels rendered
  from registered-action DTOs.

Copy conventions:

- Use direct labels on controls and headings; keep technical detail bounded and
  redacted.
- Prefer operator action text over implementation terms when the UI is interactive.
- Do not surface secret refs, raw prompts, endpoint URLs, provider bodies, or raw
  descriptor/evidence payloads.
- Status copy must state the current state first, then the available action when
  one exists.
- **Navigating controls name their destination (ADR 0080 §5, v0.61b).** A bare
  status chip must not navigate. Chips that navigate carry the
  `allbert-chip-link` affordance (hover underline, focus ring, pointer cursor)
  and a visible label naming status + destination context — the chat-header
  objective chips read status + the truncated objective title (e.g.
  "Running · Ship weekly digest"), with an accessible name of the form
  "View objective <title> — status: running"; three or more active objectives
  collapse to two chips plus a "+N more" link to `/objectives`.

## Variant Registry

Catalog variants are component props. `AllbertAssistWeb.Workspace.Components.Patterns`
is the current registry owner for the M7 baseline:

```heex
<.workspace_button variant="primary" tone="neutral" size="sm" />
<.status_badge tone="warning" />
<.workspace_panel kind="operator" density="compact" />
```

Implemented M7 registry:

- button variants: `primary`, `secondary`, `danger`;
- status tones: `info`, `neutral`, `warning`, `danger`, `success` plus `warn`,
  `error`, and `ok` aliases.

Catalog `:button`, `:action_button`, and `:status_badge` consume these props.
Avoid class-string branching at call sites. Add a variant only when multiple
callers need the distinction or the active plan names the state. Unknown explicit
variants fail fast.

## Shared Patterns

The pattern library owns behavior that is otherwise easy to drift. v0.58
acceptance is the shipped baseline:

- modal/popover: `role="dialog"`, `aria-modal`, focus trap, Esc, click-away,
  labelled heading (v0.58 acceptance);
- drawer: focus handoff, keyboard close, stable sizing, no layout shift (v0.58
  shell contract);
- empty state: bounded copy, no fake data (v0.58 catalog atoms);
- variant-controlled buttons and status affordances (v0.58 acceptance);
- loading/streaming: consistent live-region semantics;
- error/status callout: redacted technical detail, operator action when available
  through shared callout primitives;
- table/list: bounded rows, explicit sort/filter affordance points, no raw secret
  or endpoint data.

Hand-built modals and page-local loading/error shapes are v0.58 cleanup targets.

Implemented M7 modal baseline:

- `Patterns.workspace_modal/1` renders the overlay + dialog section with
  `data-workspace-pattern="modal"`, `role="dialog"`, `aria-modal="true"`,
  `aria-labelledby`, optional `aria-describedby`, `phx-hook="FocusTrap"`,
  optional Escape handling, and optional click-away handling.
- The approval handoff uses the shared modal pattern.
- The tile inspector carries the shared modal pattern marker and the same dialog/
  FocusTrap/Escape/click-away semantics while retaining the static root tag
  required by Phoenix stateful LiveComponents.

Implemented M13.1E/F shared pattern baseline:

- `Patterns.status_callout/1` and `Patterns.error_callout/1` own status/error
  callout semantics and redacted body/action slots. The LiveView offline banner
  routes through the status-callout component; the static offline fallback shell
  mirrors the same `data-workspace-pattern="status-callout"` contract in plain
  HTML.
- `Patterns.loading_state/1` owns loading live-region semantics.
- `Patterns.drawer_shell/1` owns the stateless drawer shell component, while
  `Patterns.drawer_shell_class/1` and `Patterns.drawer_shell_attrs/1` own the
  root-safe drawer contract used by stateful catalog atoms.
- `Patterns.table_list/1`, `Patterns.table_row/1`, and `Patterns.table_column/1`
  own the stateless table/list primitive baseline, while
  `Patterns.table_list_class/1`, `Patterns.table_list_attrs/1`,
  `Patterns.table_row_class/1`, `Patterns.table_row_attrs/0`,
  `Patterns.table_column_class/1`, and `Patterns.table_column_attrs/0` own the
  root-safe contract used by stateful catalog atoms.
- Stateful `UtilityDrawer`, `Table`, `Row`, and `Column` atoms preserve literal
  LiveComponent root tags and existing renderer DOM IDs/data attributes, but now
  consume the same helper contract as the stateless components. Renderer parity
  tests fail if the stateful and stateless contracts drift.

## Shell And Page Coverage

One shell wraps:

- `/` home page — a thin landing shape in v0.58 (M13.1B); **rebuilt in v0.61 as a
  real landing/marketing surface** (brand hero, feature cards, CTAs, static SEO/OG)
  through the same shell data contract, tokens, and variant-registry buttons;
- `/workspace`;
- `/jobs`;
- `/objectives/:id` objective detail pages;
- Intents panel;
- Settings/Models panel;
- Surface-Policy panel.

Jobs and Objectives are part of the v0.58 proof because design-system tokens and
a11y must apply beyond the workspace route. The `/` home page is part of the
M13.1 proof because it was the remaining first-viewport bypass; M13.1B closed it
with a thin landing page rather than full catalog content.

Implemented M8 shell baseline:

- `Layouts.operator_shell/1` owns shared header, nav, mobile shellbar, shell data
  attributes, and a token-backed body grid for non-workspace operator pages.
- `/jobs` renders through `WorkspaceRenderer` using declared `job_card`, `button`,
  and `empty_state` catalog atoms. The old table markup is removed while existing
  run/pause/resume DOM IDs and events remain stable; job-card actions use the
  catalog action-row child layout.
- `/objectives/:id` renders summary, action buttons, acceptance rows, steps, events,
  and missing state through catalog atoms; the cancel form is hosted in the shared
  modal pattern.
- `/workspace` keeps its renderer-owned chat/canvas shell and carries the shared
  operator-shell data contract, beside the persistent product sidebar
  (`.workspace-with-sidebar`) and the Direction C chat-primary hero. **v0.61b
  update (ADR 0080):** the workspace appbar is retired; the canvas/tool region is
  a right-docked resizable split pane (never a floating overlay) with
  replace-and-restore tenancy between canvas content and one `workspace:*`
  destination panel.
- **v0.61 update:** the explicit `/objectives` index route now exists (paired with
  `/objectives/:id`); the Objectives nav item resolves there, not back to workspace.

## Workspace Layout

The workspace default is chat-primary (v0.61b, ADR 0080):

- chat timeline and composer are the main column;
- **Conversations** is a contextual sidebar section (UI strings only) with
  inline thread rename (Enter saves, Escape cancels, double-click accelerator)
  through the registered `rename_thread` action;
- the canvas/tool region is a right-docked resizable split pane
  (`WorkspaceSplitResizer`, clamp 35–70, width persisted client-side; slim
  right-edge reopen tab when collapsed); nothing floats over chat;
- ephemeral surfaces render through shared modal/popover patterns, in the pane
  column on desktop;
- mobile collapses to a single-column shell with stable controls; the launcher
  opens the sidebar as an overlay drawer.

Do not rename internal `Conversations.Thread` modules, topics, settings keys,
events, or database concepts. Do not rename `Session.Scratchpad`.

Chat message type hierarchy (v0.61b M1, ADR 0074 token contract): strict
**body > sender label > timestamp** — body `--allbert-font-size-md`/400 in the
product sans face (monospace stays reserved for code-like content), sender
label `--allbert-font-size-sm`/600, timestamp `--allbert-font-size-xs`/400 on
the muted color token. Token-driven only; no hardcoded sizes in the message
rules.

Implemented M9 workspace layout baseline:

- `/workspace` emits `data-layout-mode="chat-primary"` and `data-canvas-drawer`
  (docked open/closed) state on the shell; the shell wrappers carry
  `data-sidebar-state` (expanded/rail/hidden).
- Desktop layout is the primary Chat column beside the docked canvas pane when
  open; the split resizer is visible and draggable while the pane is docked
  (`cursor: col-resize`, double-click resets, collapse control on the divider).
- The canvas pane opens from the Chat header Canvas button, sidebar destination
  selection, direct destination URLs, and the right-edge reopen tab.
- User-visible labels say **Conversations**, **New conversation**, and
  **Copy conversation id** (now in the sidebar-footer overflow menu). Internal
  `thread_id` params, event names, modules, and storage stay unchanged.
- Ephemeral surfaces retain the shared modal/dialog semantics from the pattern
  library.

## Operator Panels

The Intents, Settings/Models, and Surface-Policy panels are catalog components on
the design system. They render v0.56/v0.58 DTOs through registered actions.

- Intents: coverage, source badges, slot counts, eval/gate status, review queue,
  edit/disable/promote affordances.
- Settings/Models: recommendation matrix, current configuration, bounded
  inventory, diagnostics.
- Surface-Policy: reads and updates the `surface_policy.*` Settings Central
  namespace through registered `surface_policy_read`/`surface_policy_update`
  actions. Rows govern per-surface/action report mode, redaction/display profile,
  bounds, and explicit raw-report affordance.

Panels may display diagnostics but they do not own authority. Gated mutations stay
registered actions and confirmation/security decisions stay outside the component.

## Accessibility And Redaction

Required checks:

- keyboard access for every control;
- visible focus rings;
- dialog labels and focus trap;
- high-contrast mode on all shell pages;
- reduced-motion mode on all shell pages;
- responsive text that does not overlap or overflow controls;
- no secret refs, raw prompts, endpoint URLs, provider bodies, or raw descriptor/
  evidence payloads.
- no raw `btn` class drift in production web source; use
  `Patterns.button_class!/1`, `Patterns.compact_button_class!/1`, or catalog
  button atoms.

## Non-Goals

- No model-generated UI.
- No new operator route for the v0.58 panels unless a later ADR says so.
- No descriptor-YAML authority over report shape.
- No internal thread/session rename.
- No route compatibility revival for `/agent` or `/settings`.

## Implementation Checklist

- tokens are global and documented;
- changed components consume tokens;
- variants are prop-driven;
- shared modal/drawer/loading/status/error/table-list baselines and catalog empty
  states replace page-local copies where those shapes exist;
- shell wraps workspace, jobs, objectives, and panels;
- `/` satisfies the shell/token/catalog contract or the ADR-accepted thin landing
  exception;
- workspace is chat-primary by default;
- ephemerals are modal/popover patterns;
- canvas is a docked resizable pane driven by destination selection (v0.61b);
- panels render DTOs through registered actions;
- a11y and redaction tests cover all changed pages;
- operator evidence follows `docs/plans/v0.58-request-flow.md`.
