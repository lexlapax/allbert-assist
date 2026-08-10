# allbert.discord — Discord Channel

Shipped source-tree channel plugin for Discord, entered through
`AllbertAssist.Plugins.Discord`.

## Contract

- Plugin id: `allbert.discord` (`kind: "channel"`, version `0.52.0`)
- Channels: `discord`
- Apps: none
- Actions: `discord_doctor`

## Why it is a plugin

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. A persistent gateway socket means the adapter must survive reconnects
without replaying already-processed events.

Registration is inert contract data. Declaring the channel grants no delivery
authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Contents

- `allbert_assist/channels/discord/adapter.ex`
- `allbert_assist/channels/discord/client.ex`
- `allbert_assist/channels/discord/client/gateway_port.ex`
- `allbert_assist/channels/discord/client/gateway_port/real.ex`
- `allbert_assist/channels/discord/client/gateway_port/stub.ex`
- `allbert_assist/channels/discord/doctor.ex`
- `allbert_assist/channels/discord/parser.ex`
- `allbert_assist/channels/discord/renderer.ex`
- `allbert_assist/plugins/discord.ex`
- `allbert_discord/settings/fragment.ex`

## How it is loaded

This is **not** a separate Mix project. Its `lib` is injected into
`apps/allbert_assist` through `elixirc_paths/1`, so it compiles into that
application; `allbert_plugin.json` is discovery metadata, not a runtime
code-loading instruction. ADR 0098 records why that boundary is a contribution
boundary rather than a compilation one.
