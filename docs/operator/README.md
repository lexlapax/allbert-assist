# Operator Docs

Operator docs explain how to run, inspect, and validate Allbert from the outside.
They should describe behavior, commands, evidence, and safety boundaries without
requiring codebase knowledge.

## Start Here

- [Onboarding](onboarding.md) - first local run from a fresh checkout.
- [Workspace](workspace.md) - `/workspace`, chat-primary layout, panels, and controls.
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

## Memory, Media, And Apps

- [Active Memory](active-memory.md)
- [Artifacts Central](artifacts-central.md)
- [Artifacts browser](artifacts-browser.md)
- [Research specialist](research-specialist.md)
- [Vision and image generation](vision-and-image-generation.md)

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
document under [plans](../plans/README.md). The current shipped line is v0.63
(tagged `v0.63.0`); see [v0.63 request flow](../plans/v0.63-request-flow.md).
v0.64 product-RC validation lives in
[v0.64 request flow](../plans/v0.64-request-flow.md).
