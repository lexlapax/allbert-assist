# ADR 0016: Channel Adapter Boundary And Identity Mapping

Status: Proposed

Date: 2026-05-14

## Context

Allbert began with CLI and LiveView as local operator surfaces. v0.16 adds the
first remote channel, Telegram, while preserving the signal-first Jido runtime,
Security Central, durable confirmations, Resource Access Security Posture,
local workspace identity, and app registration decisions made in earlier ADRs.

External channels bring external identities, provider APIs, callbacks, delivery
failures, and duplicate inbound events. Without a clear boundary, a channel
adapter could accidentally become a second runtime, a second security policy,
or an implicit account system.

## Decision

Channel adapters are delivery adapters around
`AllbertAssist.Runtime.submit_user_input/1` and registered Jido actions. They
normalize inbound provider messages, resolve configured local identity, submit
runtime requests, render responses, and record durable channel event metadata.

Channels do not own:

- intent selection
- action execution
- Security Central policy
- Resource Access grants
- confirmation storage or private mutation
- conversation history
- markdown memory
- app registry semantics

The canonical local identity remains string `user_id` from ADR 0014. External
provider identities map to local `user_id` values only through explicit
Settings Central configuration. No external identity may implicitly claim
`"local"` or any other existing local user.

For v0.16, Telegram is the first proving adapter. Telegram user IDs map to local
users through `channels.telegram.identity_map`. The bot token is stored through
Settings Secrets and referenced by `channels.telegram.bot_token_ref`.

Channel adapters may use a bounded provider client for receive/send operations
against the configured provider API. This provider transport is not a general
remote access primitive and does not authorize arbitrary HTTP requests, media
downloads, document extraction, package installs, skill imports, or browser
automation.

Inbound and callback provider events are recorded in SQLite `channel_events`
for dedupe, status, and traceability. Conversation text remains in v0.12
SQLite `Thread`/`Message` history after runtime acceptance. Channel events keep
redacted/truncated summaries rather than full raw provider payload dumps.

Provider callback actions, such as Telegram approve/deny buttons, resolve
existing durable confirmations through registered confirmation actions and
`AllbertAssist.Actions.Runner`. Callback data must be compact and must not
embed resource targets, shell commands, URLs, prompt text, credentials, or
remembered grant powers.

## Consequences

- v0.16 can add Telegram without creating hosted accounts or role-based auth.
- Tests can prove channel behavior using simulated updates and a test provider
  client without depending on live network access.
- Future channels can reuse the channel context, event dedupe model, identity
  mapping posture, and response rendering pattern.
- v0.23 security evals have concrete cross-channel surfaces to test:
  identity spoofing, callback replay, resource-scope leakage, provider payload
  injection, cross-user thread leakage, and secret redaction.

## Deferred

- Hosted accounts, OAuth, roles, and remote multi-user administration.
- Telegram webhooks and public inbound HTTP routing.
- Email, SMS, Discord, Slack, native app, browser, and MCP channels.
- Media/document download and deep remote document extraction.
- Proactive broadcast and scheduled outbound messaging.
- UI protocol interop and workspace-native channel surfaces.
