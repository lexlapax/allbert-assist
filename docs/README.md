# Allbert Documentation

This directory is the project documentation map. The top-level
[README](../README.md) explains what Allbert is; this file routes readers to the
right document set.

## Start Here

For operators trying Allbert locally (same entry sequence as the top-level
[README](../README.md) and the [operator index](operator/README.md)):

- [Quickstart: Install, Open, Chat](operator/quickstart.md) - the canonical
  Allbert 1.2 first-run path.
- [Operator workspace](operator/workspace.md) - `/workspace`, panels, and controls.
- [Optional onboarding](operator/onboarding.md) - guided profiles, provider setup,
  integrations, and repair after chat is available.
- [Local knowledge](operator/local-knowledge.md) - connect local files/notes and reviewed agent memory.
- [Active Memory](operator/active-memory.md) - review, retrieve, archive,
  restore, and Forget long-term Memory.
- [Conversation Search](operator/conversation-search.md) - search retained
  conversation history across local surfaces and scoped mapped DMs.
- [Operator guide index](operator/README.md) - all task-focused operating guides.
- [Current changelog](../CHANGELOG.md) - shipped behavior and release status.
- [Roadmap](plans/roadmap.md) - release sequence and next milestones.

For contributors:

- [Architecture diagrams](design/architecture-diagrams.md) - visual orientation
  before the detail: component map, surface/daemon topology, turn and
  confirmation flows, supervision tree, and Allbert Home layout.
- [Development guide](../DEVELOPMENT.md) - setup, commands, and verification gates.
- [Agent instructions](../AGENTS.md) - repository rules for coding agents.
- [Developer docs index](developer/README.md) - subsystem and implementation maps.
- [ADR index](adr/README.md) - architectural decisions.
- [License](../LICENSE) / [NOTICE](../NOTICE) - Apache-2.0 terms and the
  attribution redistributors must carry; the dependency-license rules live in
  the [development guide](../DEVELOPMENT.md).

## Current Release

For the shipped release line, feature summary, and history, see the
[CHANGELOG](../CHANGELOG.md) and [roadmap](plans/roadmap.md) — the canonical
sources. The plan/request-flow set for every released version lives in
[plans/archives](plans/archives/README.md); the current line is:

- Current shipped line: **v1.3.0** — [long-term memory and Search Central plan](plans/archives/v1.3-plan.md) · [request flow](plans/archives/v1.3-request-flow.md)
- Shipped source correction: **v1.3.1** — [qualification and corrective-hardening plan](plans/archives/v1.3.1-plan.md) · [request flow](plans/archives/v1.3.1-request-flow.md)
- Current source closeout: **v1.3.2** — [foundational-enablers plan](plans/archives/v1.3.2-plan.md) · [request flow](plans/archives/v1.3.2-request-flow.md) (source-only tag shipped; v1.3.0 remains the packaged Latest and v1.4 is the next binary carrier)

For release-specific validation, use the matching request-flow document rather
than this index.

## Directory Map

- [adr](adr/README.md) - accepted and proposed architecture decisions.
- [archives](archives/README.md) - superseded planning references retained for history.
- [developer](developer/README.md) - implementation contracts, subsystem maps, and gates.
- [design](design/README.md) - [architecture diagrams](design/architecture-diagrams.md),
  product-experience spec, IA, first-model path,
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
