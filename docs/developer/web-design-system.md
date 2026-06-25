# Web Design System

Status: v0.58 M6 token and UX-language baseline implemented; M7-M15 complete the
variant registry, pattern library, shared shell, catalog coverage, panels, manual
validation, and closeout.

Authority: `docs/adr/0074-web-design-system-and-ux-language.md`,
`docs/adr/0024-app-ui-contribution-and-workspace-zones.md`,
`docs/plans/v0.58-plan.md`, and
`docs/plans/v0.58-request-flow.md`.

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
| Patterns | Shared modal, popover, loading, streaming, empty, error, drawer, and table/list patterns. |
| Shell | One app shell with navigation, page header/switchers, and mobile shellbar. |
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
- **Conversations**: UI label for the thread rail and switcher only; do not rename
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

## Variant Registry

Variants are component props:

```heex
<.workspace_button variant="primary" tone="neutral" size="sm" />
<.status_badge tone="warning" />
<.workspace_panel kind="operator" density="compact" />
```

Avoid class-string branching at call sites. Add a variant only when multiple
callers need the distinction or the active plan names the state. Unknown variants
should fail fast in tests.

## Shared Patterns

The pattern library owns behavior that is otherwise easy to drift:

- modal/popover: `role="dialog"`, `aria-modal`, focus trap, Esc, click-away,
  labelled heading;
- drawer: focus handoff, keyboard close, stable sizing, no layout shift;
- loading/streaming: consistent live-region semantics;
- empty state: bounded copy, no fake data;
- error callout: redacted technical detail, operator action when available;
- table/list: bounded rows, explicit sort/filter, no raw secret or endpoint data.

Hand-built modals and page-local loading/error shapes are v0.58 cleanup targets.

## Shell And Page Coverage

One shell wraps:

- `/workspace`;
- `/jobs`;
- `/objectives` and `/objectives/:id`;
- Intents panel;
- Settings/Models panel;
- Surface-Policy panel.

Jobs and Objectives are part of the v0.58 proof because design-system tokens and
a11y must apply beyond the workspace route.

## Workspace Layout

The v0.58 workspace default is chat-primary:

- chat timeline and composer are the main column;
- the left rail is labelled **Conversations** in UI strings only;
- canvas opens through a launcher/drawer and is not co-equal by default;
- ephemeral surfaces render through shared modal/popover patterns;
- mobile collapses to a single-column shell with stable controls.

Do not rename internal `Conversations.Thread` modules, topics, settings keys,
events, or database concepts. Do not rename `Session.Scratchpad`.

## Operator Panels

The Intents, Settings/Models, and Surface-Policy panels are catalog components on
the design system. They render v0.56/v0.58 DTOs through registered actions.

- Intents: coverage, source badges, slot counts, eval/gate status, review queue,
  edit/disable/promote affordances.
- Settings/Models: recommendation matrix, current configuration, bounded
  inventory, diagnostics.
- Surface-Policy: per-surface/action report mode, redaction/display profile,
  bounds, and explicit affordance.

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
- shared modal/drawer/loading/error patterns replace page-local copies;
- shell wraps workspace, jobs, objectives, and panels;
- workspace is chat-primary by default;
- ephemerals are modal/popover patterns;
- canvas is a drawer/launcher destination;
- panels render DTOs through registered actions;
- a11y and redaction tests cover all changed pages;
- operator evidence follows `docs/plans/v0.58-request-flow.md`.
