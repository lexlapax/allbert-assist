# Operator Docs

Operator docs explain how to run, inspect, and validate Allbert from the outside.
They should describe behavior, commands, evidence, and safety boundaries without
requiring codebase knowledge.

## Start Here

The non-developer entry sequence (same order across the top-level
[README](../../README.md), [docs index](../README.md), and this page):

- [Onboarding](onboarding.md) - first packaged run and local assistant setup.
- [Workspace](workspace.md) - `/workspace`, chat-primary layout, panels, and controls.
- [Local knowledge](local-knowledge.md) - connect local files/notes and reviewed agent memory (the launch integration).
- [Model recommendations](model-recommendations.md) - which model profile to use for each purpose.
- [Voice and provider preferences](voice-and-provider-preferences.md) - voice/provider setup and expectations.

## Core Operator Surfaces

- [TUI channel](tui-channel.md)
- [Public protocol surfaces](public-protocol-surfaces.md)
- [MCP servers](mcp-servers.md)
- [Browser and research](browser-and-research.md)
- [Security hardening](security-hardening.md)
- [Allbert Home export/import](export-import.md)
- [Settings version contract](settings-version.md)

## Workflows And Capabilities

- [Plan build and workflows](plan-build-and-workflows.md)
- [Dynamic capability integration](dynamic-capability-integration.md)
- [Sandbox gate runner](sandbox-gate-runner.md)
- [Marketplace Lite](marketplace-lite.md)
- [Templated creation](templated-creation.md)
- [Self-improvement](self-improvement.md)

## Local Knowledge, Memory, Media, And Apps

- [Local knowledge](local-knowledge.md) - local files/notes + reviewed agent memory launch path.
- [Active Memory](active-memory.md)
- [Artifacts Central](artifacts-central.md)
- [Artifacts browser](artifacts-browser.md)
- [Research specialist](research-specialist.md)
- [Vision and image generation](vision-and-image-generation.md)

## Install And Release Operations

- [Install](install.md) - packaged install paths (Homebrew, curl) and verification.
- [Pi mode coding](pi-mode-coding.md) - the coding/pair-programming operator surface.
- [Release rehearsal](release-rehearsal.md) - operator release-validation rehearsal runbook.

## Channels

- [Discord](discord-channel.md)
- [Email](email-channel.md)
- [Matrix](matrix-channel.md)
- [Signal](signal-channel.md)
- [Slack](slack-channel.md)
- [Telegram](telegram-channel.md)
- [WhatsApp](whatsapp-channel.md)

## Release Validation

Release-specific operator validation belongs in the matching request-flow
document under [plans](../plans/README.md). For the current packaged release line,
see the [CHANGELOG](../../CHANGELOG.md) and [roadmap](../plans/roadmap.md); each
release's validation lives in its `docs/plans/vNN-request-flow.md`. The integrated
product-RC validation is the [v0.66 request flow](../plans/v0.66-request-flow.md).
