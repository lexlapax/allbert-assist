# Allbert Documentation

This directory is the project documentation map. The top-level
[README](../README.md) explains what Allbert is; this file routes readers to the
right document set.

## Start Here

For operators trying Allbert locally (same entry sequence as the top-level
[README](../README.md) and the [operator index](operator/README.md)):

- [Operator onboarding](operator/onboarding.md) - first local run and orientation.
- [Operator workspace](operator/workspace.md) - `/workspace`, panels, and controls.
- [Local knowledge](operator/local-knowledge.md) - connect local files/notes and reviewed agent memory.
- [Current changelog](../CHANGELOG.md) - shipped behavior and release status.
- [Roadmap](plans/roadmap.md) - release sequence and next milestones.

For contributors:

- [Development guide](../DEVELOPMENT.md) - setup, commands, and verification gates.
- [Agent instructions](../AGENTS.md) - repository rules for coding agents.
- [Developer docs index](developer/README.md) - subsystem and implementation maps.
- [ADR index](adr/README.md) - architectural decisions.

## Current Release

For the shipped release line, feature summary, and history, see the
[CHANGELOG](../CHANGELOG.md) and [roadmap](plans/roadmap.md) — the canonical
sources. The plan/request-flow set for every released version lives in
[plans/archives](plans/archives/README.md); the current line is:

- Current shipped line: **v1.0.0** — [v1.0 plan](plans/archives/v1.0-plan.md) · [v1.0 request flow](plans/archives/v1.0-request-flow.md)

For release-specific validation, use the matching request-flow document rather
than this index.

## Directory Map

- [adr](adr/README.md) - accepted and proposed architecture decisions.
- [archives](archives/README.md) - superseded planning references retained for history.
- [developer](developer/README.md) - implementation contracts, subsystem maps, and gates.
- [design](design/README.md) - product-experience spec, IA, first-model path,
  onboarding flow, persona model, entry-point/CLI UX, design-system gap artifacts,
  visual-direction captures, and layout-system/brand screenshots the shipped
  releases implement.
- [notes](notes/README.md) - source notes that inform the vision.
- [operator](operator/README.md) - local operator guides and runbooks.
- [plans](plans/README.md) - roadmap, vision, milestone plans, and request flows.
- [research](research/README.md) - research notes and design investigations.
- [samples](samples/README.md) - committed sample files for docs and validation.

## Authority

When docs disagree, use the authority order in [AGENTS.md](../AGENTS.md):
current user request, code/tests, active plan/request-flow, ADRs, roadmap,
changelog, then historical archives.
