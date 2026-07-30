# Operator Documentation

These guides explain how to install, use, connect, inspect, and recover Allbert
without requiring codebase knowledge. Start with one path; use the deeper guides
only when you need the feature they cover.

## Start Here

1. [Quickstart: Install, Open, Chat](quickstart.md) — the canonical Allbert
   1.2.0 first run. Chat opens without an onboarding or model-setup gate.
2. [Workspace](workspace.md) — conversations, Models, settings, objectives, and
   the docked canvas.
3. [Local knowledge](local-knowledge.md) — connect local notes and review what
   Allbert remembers.

Onboarding is optional after first chat. Use [Onboarding](onboarding.md) when you
want guided profiles, provider setup, integrations, or local-model repair. For
install variants, upgrades, uninstall, and artifact trust, use
[Installing Allbert](install.md).

## Everyday Operation

| I want to… | Guide |
|---|---|
| Use the browser workspace | [Workspace](workspace.md) |
| Use a persistent terminal session | [TUI channel](tui-channel.md) |
| Choose or diagnose a model | [Model recommendations](model-recommendations.md) |
| Configure voice or provider preferences | [Voice and provider preferences](voice-and-provider-preferences.md) |
| Create and steer multi-step work | [Plan, build, and workflows](plan-build-and-workflows.md) |
| Check security posture and confirmations | [Security hardening](security-hardening.md) |
| Search retained conversation history | [Conversation Search](conversation-search.md) |
| Inspect packaged license evidence | [Installing Allbert](install.md#license) (`allbert licenses`) |
| Check or migrate a Home's settings contract | [Settings version](settings-version.md) |

Packaged operators use `allbert …` and `allbert admin …`. Commands beginning
with `mix allbert.…` are source-checkout or deterministic validation twins and
require the contributor toolchain. Never run a packaged service and a
standalone/source runtime concurrently against the same Allbert Home.

## Knowledge, Memory, And Artifacts

- [Local knowledge](local-knowledge.md) — local files/notes plus reviewed agent
  memory; this is the launch integration.
- [Active Memory](active-memory.md) — identity slots, reviewed memory, retrieval,
  and trace visibility.
- [Conversation Search](conversation-search.md) — central lexical conversation
  search, mapped-DM scope, recurring index jobs, and canonical deletion.
- [Artifacts Central](artifacts-central.md) — retained media posture and bounds.
- [Artifacts browser](artifacts-browser.md) — browse, inspect, and export retained
  artifacts.
- [Allbert Home export/import](export-import.md) — portable data with dry-run
  import and explicit rollback.

## Research And Media

- [Browser and research](browser-and-research.md) — browser driver setup,
  evidence, cache, and redaction.
- [Research specialist](research-specialist.md) — bounded multi-source research.
- [Vision and image generation](vision-and-image-generation.md) — image inputs
  and generated-image artifacts.
- [Voice and provider preferences](voice-and-provider-preferences.md) — STT, TTS,
  workspace voice, and provider selection.

## Connections And Channels

- [MCP servers](mcp-servers.md) — configure, discover, inspect, and invoke MCP
  resources and tools.
- [Public protocol surfaces](public-protocol-surfaces.md) — MCP, OpenAI-compatible,
  ACP, tokens, artifacts, and protocol boundaries.
- Channel setup: [Discord](discord-channel.md), [Email](email-channel.md),
  [Matrix](matrix-channel.md), [Signal](signal-channel.md),
  [Slack](slack-channel.md), [Telegram](telegram-channel.md), and
  [WhatsApp](whatsapp-channel.md).

Each channel guide names its provider prerequisites, identity mapping, secrets,
verification, and cleanup. Connecting a channel never grants extra capability
authority. Autonomous reports remain off until explicitly enabled for that
channel.

## Create And Extend

- [Templated creation](templated-creation.md) — create reviewed document and code
  drafts from the workspace.
- [Marketplace Lite](marketplace-lite.md) — browse and install reviewed bundles.
- [Dynamic capability integration](dynamic-capability-integration.md) — draft,
  review, confirm, integrate, and roll back generated capabilities.
- [Sandbox gate runner](sandbox-gate-runner.md) — compile/test generated code in
  the bounded sandbox.
- [Self-improvement](self-improvement.md) — review suggestions and promote only
  confirmed drafts.
- [Pi-mode coding](pi-mode-coding.md) — terminal pair-programming with explicit
  approval modes and tool boundaries.

Several extension guides are source/developer-operator workflows. Their Mix
commands are intentional and are not available in the packaged CLI unless the
guide names a packaged twin.

## Install, Recovery, And Release Operations

- [Installing Allbert](install.md) — supported platforms, package paths,
  upgrades, uninstall, backups, and distribution trust.
- [Security hardening](security-hardening.md) — emergency switches, deployment,
  pairing, secret vault, and exposed-service posture.
- [Release rehearsal](release-rehearsal.md) — maintainer-only binary publication
  and cross-platform evidence runbook; it is not a first-run guide.

Release-specific validation belongs in the matching
[request-flow document](../plans/README.md), not in Quickstart. Shipped behavior
and release history live in the [CHANGELOG](../../CHANGELOG.md); sequencing lives
in the [roadmap](../plans/roadmap.md).
