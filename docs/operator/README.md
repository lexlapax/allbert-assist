# Operator Docs

Operator docs explain how to run, inspect, and validate Allbert from the outside.
They should describe behavior, commands, evidence, and safety boundaries without
requiring codebase knowledge.

## Start Here

- [Onboarding](onboarding.md) - first packaged run and local assistant setup.
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
document under [plans](../plans/README.md). The current packaged shipped line is
v0.64.3 (tagged `v0.64.3`); `v0.64.4` is a source/docs point tag only. See
[v0.64 request flow](../plans/v0.64-request-flow.md).
The next planned line is v0.65 local files/notes/memory, and product-RC
validation lives in [v0.66 request flow](../plans/v0.66-request-flow.md).
