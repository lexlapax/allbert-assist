# ADR 0030: Unified Surface Catalog, Renderer, And Extension Registry

## Status

Accepted in v0.31 M7 Runtime And UI-Substrate Consolidation
(`docs/plans/v0.31-plan.md`).

## Context

Surface component truth is currently spread across the Surface DSL, workspace
catalog helpers, web renderer dispatch, app surface catalog metadata, and
StockSage-specific rendering paths. App and plugin registries also expose
related contribution data through separate facades. v0.32 workspace panels and
v0.37 generation should not depend on several overlapping sources of truth.

## Decision

v0.31 will converge on:

- one Surface catalog facade for known component atoms, primitive status,
  catalog validation, app-declared metadata, and renderer dispatch;
- one normalized extension registry facade for compiled plugin/app
  contributions, including apps, surfaces, actions, skill roots, settings
  fragments, child specs, diagnostics, and metadata.

Apps and plugins remain distinct concepts. The unified registry is a discovery
and inspection path, not an authority grant.

Implementation note: M7 introduced `AllbertAssist.Surface.Catalog`,
`AllbertAssistWeb.Surface.Renderer`, and `AllbertAssist.Extensions.Registry`.
The v0.30 StockSage pass-through workspace adapters and
`StockSageWeb.Components.SurfaceRenderer` were retired after focused render
tests proved `/agent` and `/stocksage/*` still render the v0.27 StockSage card
DOM handles through the shared catalog path.

## v0.55 Amendment: Split Payload Rendering

Status: Proposed for v0.55 Channel Parity + TUI/Terminal Channel
(`docs/plans/v0.55-plan.md`; ADR 0067).

Renderers are extended to honor the ADR 0029 split-payload response contract:
they draw `surface_payload` when present and fall back to `model_payload` /
`message` for single-payload responses. The runtime-facing catalog remains a
discovery/rendering path, not an authority grant. The TUI terminal renderer is
the first consumer that materially diverges the two payloads: it may draw
terminal framing from `surface_payload`, while memory and subsequent model turns
consume only `model_payload`.

Implementation note (v0.55 M4): `AllbertAssist.Channels.TUI.Renderer` consumes
`surface_payload` first and falls back to `model_payload` / `message`. The
`release.v055` gate verifies that this renderer behavior stays separate from
model-facing conversation persistence.

## Consequences

- v0.32 adds workspace panels by extending one catalog/registry path.
- v0.37 scaffolds one contribution shape.
- StockSage renderers can participate in the same catalog mechanism as core
  workspace components.

## Non-Goals

- No arbitrary generated UI.
- No metadata-granted permission.
- No dynamic route creation.
- No runtime loading of home-plugin Elixir modules.

## Relates To

- Unifies surfaces declared under ADR 0015 (app/surface DSL) and ADR 0023
  (workspace canvas/catalog).
- Under: ADR 0026 facade discipline.
- Distinct from ADR 0027's action registry (see ADR 0027 "Terminology").
- Enables: ADR 0024 (v0.32 panels/zones extend this one catalog/registry path)
  and the v0.38 generator contribution shape.
