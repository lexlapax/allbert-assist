# Allbert Documentation

This directory is the project documentation map. The top-level
[README](../README.md) explains what Allbert is; this file routes readers to the
right document set.

## Start Here

For operators trying Allbert locally:

- [Operator onboarding](operator/onboarding.md) - first local run and orientation.
- [Operator workspace](operator/workspace.md) - `/workspace`, panels, and controls.
- [Current changelog](../CHANGELOG.md) - shipped behavior and release status.
- [Roadmap](plans/roadmap.md) - release sequence and next milestones.

For contributors:

- [Development guide](../DEVELOPMENT.md) - setup, commands, and verification gates.
- [Agent instructions](../AGENTS.md) - repository rules for coding agents.
- [Developer docs index](developer/README.md) - subsystem and implementation maps.
- [ADR index](adr/README.md) - architectural decisions.

## Current Release

- [v0.61b plan](plans/v0.61b-plan.md)
- [v0.61b request flow](plans/v0.61b-request-flow.md)
- [v0.61 plan](plans/v0.61-plan.md)
- [v0.61 request flow](plans/v0.61-request-flow.md)
- [Surface contract](developer/surface-contract.md)
- [Web design system](developer/web-design-system.md)
- [Operator workspace guide](operator/workspace.md)

The current release is `v0.61.0` (Presentation Layer Overhaul): the v0.60 IA
implemented in the operator-chosen Layout D (Sidebar-primary), dressed in the
v0.60b-chosen Direction C (Soft Modern Depth) visual language, with brand, motion,
visual hierarchy, landing, and dark-mode polish; `release.v061` is green and the
tag `v0.61.0` is applied; version metadata reports `0.61.0`. In flight is
**v0.61b** (planned, releases as `0.61.1`): a UX-refinement point release that
implements the operator's v0.61 manual-validation feedback — navigation
consolidation (one sidebar, docked tool pane, no top bars, collapsible rail; ADR
0080) plus chat type-scale, status-chip labeling, renamable threads, and a subtler
dark mode. The remaining pre-1.0 arc is v0.62 packaging/entry points, v0.63 guided
onboarding/profiles, and v0.64 product RC; see the [plans index](plans/README.md)
and [roadmap](plans/roadmap.md). The v0.60/v0.60b design artifacts live under
`docs/design/` (including `visual-directions/` rendered captures); v0.61 adds the
committed sanitized layout screenshot record under `docs/design/layout-systems/`
and the committed brand candidate/selected rendering record under
`docs/design/brand/`; v0.61b records the consolidated-shell spec and S2 sign-off
inside the v0.61b plan rather than adding a separate design artifact. The
plan/request-flow docs retain the validation evidence and release handoff.

## Directory Map

- [adr](adr/README.md) - accepted and proposed architecture decisions.
- [archives](archives/README.md) - superseded planning references retained for history.
- [developer](developer/README.md) - implementation contracts, subsystem maps, and gates.
- design (created by v0.60) - product-experience spec, IA, first-model path,
  onboarding flow, persona model, entry-point/CLI UX, design-system gap artifacts,
  visual-direction captures, and v0.61 layout-system/brand screenshots consumed by
  v0.61-v0.63.
- [notes](notes/README.md) - source notes that inform the vision.
- [operator](operator/README.md) - local operator guides and runbooks.
- [plans](plans/README.md) - roadmap, vision, milestone plans, and request flows.
- [research](research/README.md) - research notes and design investigations.
- [samples](samples/README.md) - committed sample files for docs and validation.

## Authority

When docs disagree, use the authority order in [AGENTS.md](../AGENTS.md):
current user request, code/tests, active plan/request-flow, ADRs, roadmap,
changelog, then historical archives.
