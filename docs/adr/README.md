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
- [ADR 0084: Autonomous channel notification authority](0084-autonomous-channel-notification-authority.md) (Accepted — v1.1; v1.8 `:suggestion` amendment Proposed until M8)
- [ADR 0085: Cooperative cancellation and child-process kill](0085-cooperative-cancellation-and-child-process-kill.md)
- [ADR 0086: Test global-state ownership conversion contracts](0086-test-global-state-ownership-conversion.md)
- [ADR 0087: Zero-click first run and detection-based enablement](0087-zero-click-first-run-and-detection-based-enablement.md) (Accepted — v1.2)
- [ADR 0088: Model catalog, chooser, and fallback/degradation policy](0088-model-catalog-chooser-and-fallback-policy.md) (Accepted — v1.2)
- [ADR 0089: Long-term user memory architecture and consent boundary](0089-long-term-user-memory-architecture-and-consent.md) (Accepted — v1.3 M9.b.1; v1.3.1 full-build-watermark clarification)
- [ADR 0090: Adaptive usage profiling and confirmed customization](0090-adaptive-usage-profiling-and-confirmed-customization.md) (Proposed — accepts only at v1.8 M8)
- [ADR 0091: Daemon-backed TUI session protocol and thin terminal client](0091-daemon-backed-tui-session-protocol.md) (Accepted — v1.2.5 M0.b1)
- [ADR 0092: Search Central and conversation FTS](0092-search-central-and-conversation-fts.md) (Accepted — v1.3; v1.3.1 paused-managed-due correction)
- [ADR 0093: Canonical conversation deletion and retention boundary](0093-canonical-conversation-deletion-and-retention-boundary.md) (Accepted — v1.3, 2026-07-30)
- [ADR 0094: Knowledge Central and the derived wiki projection](0094-knowledge-central-and-derived-wiki.md) (Proposed — v1.5/v1.6)
- [ADR 0095: Knowledge schema authority and untrusted source ingestion](0095-knowledge-schema-authority-and-untrusted-source-ingestion.md) (Proposed — v1.5/v1.6)
- [ADR 0096: Delegated OAuth authority and token lifecycle](0096-delegated-oauth-authority-and-token-lifecycle.md) (Proposed — v1.7)
- [ADR 0097: Answering-head qualification bar](0097-answering-head-qualification-bar.md) (Accepted — v1.3.1)
- [ADR 0098: Kernel application, pack contract, and tier model](0098-kernel-application-pack-contract-and-tier-model.md) (Accepted for implementation — v1.4; closeout records the realized inventory)
- [ADR 0070: TUI operator console and read-only operator actions](0070-tui-operator-console-and-read-only-operator-actions.md)
- [ADR 0068: Pi-mode coding surface and local coding trust tier](0068-pi-mode-coding-surface-and-local-coding-trust-tier.md)
- [ADR 0065: Central action param contract enforcement](0065-central-action-param-contract-enforcement.md) (Accepted — v0.59; v1.4 clarification keeps authorization separate)
- [ADR 0046: Settings schema migration policy](0046-settings-schema-migration-policy.md) (Accepted — v0.59; v1.4 admission found no consumer and the runner remains deferred)

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
