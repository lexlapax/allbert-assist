# Architecture Decision Records

ADRs record binding design decisions. They are not release plans; use
[roadmap](../plans/roadmap.md) and the active plan/request-flow for release scope.

## Current High-Impact ADRs

- [ADR 0073: Cross-surface contract](0073-cross-surface-contract.md)
- [ADR 0074: Web design system and UX language](0074-web-design-system-and-ux-language.md)
- [ADR 0075: User-category settings profiles](0075-user-category-settings-profiles.md)
- [ADR 0076: Packaging, distribution, and unified CLI entry points](0076-packaging-distribution-and-unified-cli.md)
- [ADR 0077: Product experience design and information architecture](0077-product-experience-design-and-information-architecture.md)
- [ADR 0078: First-model path](0078-first-model-path.md)
- [ADR 0079: Visual design language and art direction](0079-visual-design-language-and-art-direction.md)
- [ADR 0080: Navigation consolidation and workspace shell presentation](0080-navigation-consolidation-and-workspace-shell-presentation.md)
- [ADR 0081: Tier-2 → Tier-1 contract promotion process](0081-tier2-to-tier1-promotion-process.md)
- [ADR 0082: Registry injection seams for test isolation](0082-registry-injection-seams-for-test-isolation.md)
- [ADR 0083: Objectives parallel child fan-out](0083-objectives-parallel-child-fanout.md)
- [ADR 0084: Autonomous channel notification authority](0084-autonomous-channel-notification-authority.md)
- [ADR 0085: Cooperative cancellation and child-process kill](0085-cooperative-cancellation-and-child-process-kill.md)
- [ADR 0086: Test global-state ownership conversion contracts](0086-test-global-state-ownership-conversion.md)
- [ADR 0070: TUI operator console and read-only operator actions](0070-tui-operator-console-and-read-only-operator-actions.md)
- [ADR 0068: Pi-mode coding surface and local coding trust tier](0068-pi-mode-coding-surface-and-local-coding-trust-tier.md)
- [ADR 0065: Central action param contract enforcement](0065-central-action-param-contract-enforcement.md)
- [ADR 0046: Settings schema migration policy](0046-settings-schema-migration-policy.md)

## Foundational ADR Clusters

- Runtime, memory, settings, home, and security: ADR 0001-0014.
- App, plugin, surface, workspace, and catalog contracts: ADR 0015-0031.
- Dynamic capability, sandbox, MCP, browser, workflows, and marketplace: ADR 0032-0045.
- Provider, artifact, channel, intent, and model contracts: ADR 0046-0072.
- v0.58 consolidation and pre-1.0 product contracts: ADR 0073-0080.

## How To Read

Prefer the latest accepted ADR for a subsystem, then follow amendments called out
in the active release plan. When an ADR and current code disagree, flag the drift
instead of silently following stale text.
