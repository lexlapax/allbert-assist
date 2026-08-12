# allbert.slack — Slack Channel

Shipped source-tree channel plugin for Slack, entered through
`AllbertSlack.Plugin`.

## Contract

- Plugin id: `allbert.slack` (`kind: "channel"`, version `0.52.0`)
- Channels: `slack`
- Apps: none
- Actions: `slack_doctor`

## Why it is a plugin

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Socket Mode gives a persistent connection whose identity map is
workspace-scoped, so a DM and a channel post are not the same trust context.

Registration is inert contract data. Declaring the channel grants no delivery
authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Contents

- `allbert_assist/channels/slack/adapter.ex`
- `allbert_assist/channels/slack/client.ex`
- `allbert_assist/channels/slack/client/socket_mode_port.ex`
- `allbert_assist/channels/slack/client/socket_mode_port/real.ex`
- `allbert_assist/channels/slack/client/socket_mode_port/stub.ex`
- `allbert_assist/channels/slack/doctor.ex`
- `allbert_assist/channels/slack/parser.ex`
- `allbert_assist/channels/slack/renderer.ex`
- `allbert_assist/plugins/slack.ex`
- `allbert_slack/settings/fragment.ex`

## How it is loaded

This is **not** a separate Mix project. Its `lib` is injected into
`apps/allbert_assist` through `elixirc_paths/1`, so it compiles into that
application; `allbert_plugin.json` is discovery metadata, not a runtime
code-loading instruction. ADR 0098 records why that boundary is a contribution
boundary rather than a compilation one.
