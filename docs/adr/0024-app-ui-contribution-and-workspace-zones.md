# ADR 0024: App UI Contribution And Workspace Zones

## Status

Proposed for v0.31 Workspace-Native Plugin UI And User Theming
(`docs/plans/v0.31-plan.md`). This ADR graduates the "Workspace Hooks" /
plugin-contributed workspace regions reserved in ADR 0023 §1, extends the
Surface DSL of ADR 0015 with a panel contribution tier and host-owned zones,
and pins the `/apps/<app_id>` route convention and the ChatGPT-style workspace
shell.

## Context

Allbert has two parallel UI worlds that do not compose:

- `/agent` is a fully dynamic workspace: the shell is itself a Surface tree
  built by `AllbertAssist.Workspace.Catalog.workspace_tree/1`, walked by the
  renderer, dispatched to LiveComponents per `:component` atom (ADR 0023 §2).
- Apps such as StockSage instead ship hand-written full-page LiveViews under
  hardcoded `/stocksage/*` routes (compiled into the host via
  `shipped_plugin_web_paths/0`), with private navigation (`AppShell.nav`) and
  large amounts of embedded Tailwind. v0.30 lets them emit durable canvas
  *tiles*, but they cannot contribute *regions/panels* to the workspace.

ADR 0023 §1 reserved "Workspace Hooks (plugin-contributed workspace
extensions)" and §2 noted "Plugins can contribute regions via
`SurfaceProvider.surfaces/0` (future work, post-v0.31)." The operator direction
for v0.31 is to make the workspace the primary surface for app UI and reserve
dedicated routes only for genuinely page-shaped views.

Mature extensible apps converge on a two-tier model: a rare *page* primitive
(own route) and a default *panel/card* primitive that targets a host-owned
named slot — VS Code `viewsContainers` vs `views`, Grafana app-page vs panel,
Backstage `PageBlueprint` vs `EntityCardBlueprint`, Home Assistant panel vs
Lovelace card, JupyterLab named shell areas, Discourse plugin outlets. The host
owns layout and slots; the app declares *what* and *which slot*, never the
container. Allbert already has the substrate (declarative Surface tree +
curated catalog), so the change is a contribution tier and a zone registry, not
a new rendering mechanism.

## Decision

### 1. Two contribution tiers

`AllbertAssist.App.SurfaceProvider` surfaces carry an explicit kind:

- **Page surface**: owns a route. Reserved for self-contained, deep-linkable,
  page-shaped views. Rare.
- **Panel surface**: a validated Surface subtree targeting a host-owned named
  zone, composed into `/agent`. The default app UI contribution; never routed.

A panel surface is a declarative Surface node validated against the catalog at
registration and render time, exactly like every other Surface. Apps never ship
arbitrary HTML/CSS/JS for a panel.

### 2. Host-owned named zones (fixed set)

`AllbertAssist.Workspace.Catalog` declares a fixed zone set for v0.31:
`:nav_apps`, `:context_rail`, `:canvas_panels`, `:ephemeral`. `workspace_tree/1`
composes the `CoreApp` base shell plus every registered app's panel surfaces
into their declared zones. Expanding the zone set is a future catalog
amendment, not an open registration surface. A panel's `zone` and optional
`visible_when` are ranking/visibility metadata only, never authority (consistent
with ADR 0019 and ADR 0021).

### 3. `/apps/<app_id>` route namespace

Page surfaces standardize on `/apps/<app_id>/...`. Routes remain compile-time
declared in the host router; v0.31 adds no dynamic/runtime route creation.
StockSage reduces to a single page route, `/apps/stocksage/analyses/:id`. A
`/stocksage/* → /apps/stocksage/*` redirect is optional, not a maintained
compatibility layer.

### 4. ChatGPT-style three-zone shell

`CoreApp.surfaces/0` declares a three-zone shell: a collapsible left rail
(new-chat + thread history from existing `recent_threads/1` + the `:nav_apps`
app launcher + `:context_rail`), a center chat thread, and a right canvas
holding `:canvas_panels` and durable tiles. New structural catalog atoms
`:nav_rail`, `:thread_list`, and `:app_launcher` are added (host structural
chrome, not model-facing component types). Existing two-pane behaviors (offline
tile editing, WCAG-AA accessibility, mobile responsiveness, split resizer) are
preserved; the mobile `data-mobile-tab` system gains a `nav` drawer state.

### 5. One path for built-in and plugin apps

`CoreApp`'s own domain cards (objective, job, confirmation) are declared as
panel surfaces in zones. `CoreApp` is the reference implementer of the panel
contract; StockSage is the second. No app has a private composition path.

### 6. Security boundaries (unchanged authority model)

Panels and zones add no new authority:

- Panels render only catalog-allow-listed components (catalog bypass eval,
  v0.28).
- Dynamic tile data still flows through the v0.30 signed Fragment path and the
  `AllbertAssist.Workspace.Fragment.Guard` emitter allow-list.
- App-scoped actions still require explicit `active_app` (v0.28); `zone` and
  `visible_when` never authorize.

## Consequences

- Apps contribute most UI as panels; the host owns layout and slots, so app UI
  composes consistently and is inspectable as a Surface tree.
- StockSage loses ~2k lines of embedded page LiveView/Tailwind and its private
  nav; the workspace becomes the single navigation surface.
- The catalog grows by three structural atoms; ADR 0015's catalog count is
  amended accordingly.
- Adding a new app still touches the compile-time router for any page surface;
  the v0.32 generator templates that block.
- The fixed zone set may need to become registry-driven with priorities once
  several apps contribute panels; deferred until a real third app exists.

## Relates To

- Extends: ADR 0015 (Allbert App Contract And Surface DSL) — adds the `:panel`
  surface kind, named zones, the `/apps/<app_id>` convention, and the
  `:nav_rail`/`:thread_list`/`:app_launcher` catalog atoms.
- Graduates: ADR 0023 §1 "Workspace Hooks" / §2 plugin-contributed regions.
- Constrained by: ADR 0019 and ADR 0021 (metadata is not authority), ADR 0017
  (plugin contract), v0.28 security posture.
- Pairs with: ADR 0025 (User Theming And Override Security) for the
  operator-owned theming/layout layers.
- Enables: v0.32 Plugin And App Generator (`docs/plans/v0.32-plan.md`) and the
  post-v0.31 UI Protocol Interop work.
