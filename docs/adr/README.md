# Architecture Decision Records

ADRs record binding design decisions. They are not release plans; use
[roadmap](../plans/roadmap.md) and the active plan/request-flow for release scope.

## Current High-Impact ADRs

- [ADR 0073: Cross-surface contract](0073-cross-surface-contract.md)
- [ADR 0074: Web design system and UX language](0074-web-design-system-and-ux-language.md)
- [ADR 0070: TUI operator console and read-only operator actions](0070-tui-operator-console-and-read-only-operator-actions.md)
- [ADR 0068: Pi-mode coding surface and local coding trust tier](0068-pi-mode-coding-surface-and-local-coding-trust-tier.md)
- [ADR 0065: Central action param contract enforcement](0065-central-action-param-contract-enforcement.md)
- [ADR 0046: Settings schema migration policy](0046-settings-schema-migration-policy.md)

## Foundational ADR Clusters

- Runtime, memory, settings, home, and security: ADR 0001-0014.
- App, plugin, surface, workspace, and catalog contracts: ADR 0015-0031.
- Dynamic capability, sandbox, MCP, browser, workflows, and marketplace: ADR 0032-0045.
- Provider, artifact, channel, intent, and model contracts: ADR 0046-0072.
- v0.58 consolidation contracts: ADR 0073-0074.

## How To Read

Prefer the latest accepted ADR for a subsystem, then follow amendments called out
in the active release plan. When an ADR and current code disagree, flag the drift
instead of silently following stale text.
