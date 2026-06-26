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

- [v0.58 plan](plans/v0.58-plan.md)
- [v0.58 request flow](plans/v0.58-request-flow.md)
- [Surface contract](developer/surface-contract.md)
- [Web design system](developer/web-design-system.md)
- [Operator workspace guide](operator/workspace.md)

v0.58 is released as `v0.58.0`. v0.59 is the next hardening and RC-prep release:
[v0.59 plan](plans/v0.59-plan.md), [v0.59 request flow](plans/v0.59-request-flow.md).

## Directory Map

- [adr](adr/README.md) - accepted and proposed architecture decisions.
- [archives](archives/README.md) - superseded planning references retained for history.
- [developer](developer/README.md) - implementation contracts, subsystem maps, and gates.
- [notes](notes/README.md) - source notes that inform the vision.
- [operator](operator/README.md) - local operator guides and runbooks.
- [plans](plans/README.md) - roadmap, vision, milestone plans, and request flows.
- [research](research/README.md) - research notes and design investigations.
- [samples](samples/README.md) - committed sample files for docs and validation.

## Authority

When docs disagree, use the authority order in [AGENTS.md](../AGENTS.md):
current user request, code/tests, active plan/request-flow, ADRs, roadmap,
changelog, then historical archives.
