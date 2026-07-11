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

- [v0.62 plan](plans/v0.62-plan.md)
- [v0.62 request flow](plans/v0.62-request-flow.md)
- [v0.63 plan](plans/v0.63-plan.md)
- [v0.63 request flow](plans/v0.63-request-flow.md)
- [v0.64 plan](plans/v0.64-plan.md)
- [v0.64 request flow](plans/v0.64-request-flow.md)
- [v0.65 plan](plans/v0.65-plan.md)
- [v0.65 request flow](plans/v0.65-request-flow.md)
- [v0.66 plan](plans/v0.66-plan.md)
- [v0.66 request flow](plans/v0.66-request-flow.md)
- [Operator onboarding](operator/onboarding.md)
- [Operator workspace guide](operator/workspace.md)

The current packaged release line is **v0.65.0 (Local Knowledge: Files, Notes, And Agent
Memory), tagged `v0.65.0`** (Latest, 2026-07-11): local files/notes plus reviewed agent
memory are the primary post-first-chat workflow — a config-free notes-root connect
affordance (`allbert admin notes set-root` / onboarding / web), the action-backed
`workspace:notes` search/read destination, the interactive `workspace:memory` review panel
(keep/reject/delete, only kept memory is recalled), `admin memory status`, and natural-chat
"remember X" / "show what you remember". No new authority. See
[local-knowledge](operator/local-knowledge.md). The prior packaged line was v0.64.3
(Trusted Install & Non-Developer First Run); `v0.64.4`/`v0.64.5` were `[skip-artifacts]`
docs/source tags. v0.66 owns product RC next.

The v0.60/v0.60b design artifacts live under `docs/design/`; v0.61/v0.61b record
the web shell and presentation work; v0.62 records packaging, first-model path,
and three-tier vault; v0.63 records the guided onboarding/profile implementation; v0.64
records trusted install and non-developer first-run hardening.
For release-specific validation, use the matching request-flow document rather
than this index.

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
