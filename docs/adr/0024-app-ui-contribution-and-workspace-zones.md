# ADR 0024: App UI Contribution And Workspace Zones

## Status

Accepted and implemented in v0.32 Workspace-Only App UI And Settings Central
(`docs/plans/v0.32-plan.md`). This ADR graduates the "Workspace Hooks" /
plugin-contributed workspace regions reserved in ADR 0023 §1, extends the
Surface DSL of ADR 0015 with a panel contribution tier and host-owned zones,
pins `/workspace` as the canonical operator route, and moves Settings Central
into the workspace utility drawer. Conversational app-intent inference is not
part of this ADR; v0.33 / ADR 0034 adds explicit handoff and clarification
after the workspace app selector exists.

## Context

Before v0.32, Allbert had several operator UI surfaces:

- `/agent` is the dynamic workspace shell built from
  `AllbertAssist.Workspace.Catalog.workspace_tree/1`, rendered through the
  Surface catalog.
- `/settings` is a separate Settings Central LiveView.
- Apps such as StockSage ship hand-written full-page LiveViews under
  `/stocksage/*`, with private navigation and app-specific page chrome.

v0.30 lets StockSage emit durable canvas tiles into the workspace, but app
dashboard/list/queue/trend UI still lived outside the workspace. v0.31
consolidated the runtime/catalog/settings substrate first. v0.32 sharpens the
operator model: the product home is `/workspace`, most app UI is a panel
inside that workspace, Settings Central is a workspace utility panel, and old
operator routes are removed rather than redirected.

Mature extensible apps converge on a host-owned slot model: rare page
surfaces for deep-linkable page flows, and default panels/cards/views that
target named host regions. The host owns layout and slots; the app declares
what it can contribute and where it prefers to appear. Allbert already has the
substrate for this through Surface trees and the v0.31 unified component
catalog, so v0.32 adds a contribution tier and zone registry rather than a new
rendering mechanism.

## Decision

### 1. `/workspace` is canonical

The operator product route is `/workspace`.

`/agent`, `/settings`, and `/stocksage/*` are removed in v0.32. They are not
redirected, aliased, or retained as compatibility routes. Historical docs may
continue to describe those routes for v0.30 and earlier.

### 2. Two contribution tiers

`AllbertAssist.App.SurfaceProvider` surfaces carry an explicit kind:

- **Panel surface**: a validated Surface subtree targeting a host-owned named
  zone in `/workspace`. This is the default for dashboards, lists, queues,
  trends, status, settings, summaries, and controls.
- **Page surface**: a compile-time host route under `/apps/<app_id>/...`,
  reserved for self-contained, deep-linkable, page-shaped views that cannot
  reasonably fit as workspace panels.

A panel surface is validated against the catalog at registration and render
time. Apps never ship arbitrary HTML/CSS/JS for a panel, and app metadata does
not grant route or layout authority.

### 3. Host-owned named zones

The v0.31 unified Surface catalog declares a fixed zone set for v0.32:

- `:nav_apps`
- `:context_rail`
- `:canvas_panels`
- `:utility_drawer`
- `:ephemeral`

`workspace_tree/1` composes the CoreApp shell plus registered app panels into
these zones. Expanding the zone set later is a catalog amendment, not an open
registration surface. A panel's `zone`, `order`, and `visible_when` are
visibility/ranking metadata only, never authority.

The `:nav_apps` zone owns explicit app selection. Selecting an app sets active
app context through the existing registered/session boundary. It is context for
ranking and panel visibility, not authorization, and it does not execute an
action.

### 4. Workspace shell

`CoreApp.surfaces/0` declares the `/workspace` shell: a collapsible left rail,
center thread, right canvas/panel area, and utility drawer. New structural
catalog atoms include `:workspace_shell`, `:nav_rail`, `:thread_list`,
`:app_launcher`, `:utility_drawer`, and `:workspace_panel`. These are host
structural chrome, not model-facing component types.

Existing canvas and ephemeral behaviors from ADR 0023 remain: signed Fragment
emission, durable tile persistence, multi-tab sync, accessibility, mobile
responsiveness, and offline editing.

### 5. Settings Central is a utility panel

Settings Central renders inside `/workspace` through the utility drawer. It
uses the existing Settings Central actions, redaction helpers, confirmation
flows, remembered-grant controls, and audit behavior. The UI does not own
settings semantics, secret storage, permission decisions, or confirmation
policy.

### 6. One path for built-in and plugin apps

CoreApp domain cards and StockSage panels use the same panel-zone mechanism.
CoreApp is the reference implementer; StockSage is the first plugin app to move
from route-owned app UI to workspace panels. No app has a private composition
path.

### 7. Security boundaries are unchanged

Panels and zones add no new authority:

- Panels render only catalog-allow-listed components.
- Dynamic tile data still flows through the v0.30 signed Fragment path and the
  `AllbertAssist.Workspace.Fragment.Guard` emitter allow-list.
- Settings writes still flow through Settings Central actions and existing
  security decisions.
- App-scoped actions still require explicit `active_app`.
- App selection is an explicit context transition, not permission.
- `zone`, `order`, and `visible_when` never authorize behavior.

## Consequences

- `/workspace` becomes the single operator product surface.
- Settings Central is available where the operator works, rather than as a
  separate route.
- StockSage loses its private dashboard/list/queue/trend routes and app nav;
  those workflows become workspace panels.
- `StockSageWeb.AnalysisLive` remains under `/apps/stocksage/analyses/:id`
  because the detail flow is page-shaped: long-form surface-node review,
  objective/progress streaming, rerun controls, reflection generation, and
  explicit lesson-sync confirmation do not fit the v0.32 panel surface well.
- The catalog grows by host structural atoms and panel wrappers; ADR 0015 is
  amended accordingly.
- The fixed zone set may need to become richer after more apps contribute
  panels, but v0.32 keeps the surface intentionally small.

## Relates To

- Extends: ADR 0015 (Allbert App Contract And Surface DSL) — adds the `:panel`
  surface kind, named zones, `/workspace` as canonical operator route, and the
  `/apps/<app_id>` convention for rare page surfaces.
- Depends on: ADR 0030 / v0.31 unified Surface catalog and extension registry,
  and ADR 0031 / v0.31 settings fragments.
- Graduates: ADR 0023 §1 "Workspace Hooks" / §2 plugin-contributed regions.
- Constrained by: ADR 0019 and ADR 0021 (metadata is not authority), ADR 0017
  (plugin contract), and v0.28 security posture.
- Enables: ADR 0034 / v0.33 app intent handoff and clarification, ADR 0025 /
  v0.34 user theming and layout overrides, v0.35 dynamic plugin/app draft
  trials, then v0.36 Plugin And App Generator.
