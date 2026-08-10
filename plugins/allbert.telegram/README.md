# allbert.telegram — Telegram Channel

Shipped source-tree channel plugin for Telegram, entered through
`AllbertAssist.Plugins.Telegram`.

## Contract

- Plugin id: `allbert.telegram` (`kind: "channel"`, version `0.17.0`)
- Channels: `telegram`
- Apps: none
- Actions: none. The channel is delivery only.

## Why it is a plugin

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Bot-API delivery is long-poll based, so the adapter owns its own receive
loop and de-duplicates by external message id.

Registration is inert contract data. Declaring the channel grants no delivery
authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Contents

- `allbert_assist/channels/telegram/adapter.ex`
- `allbert_assist/channels/telegram/client.ex`
- `allbert_assist/channels/telegram/doctor.ex`
- `allbert_assist/channels/telegram/parser.ex`
- `allbert_assist/channels/telegram/renderer.ex`
- `allbert_assist/plugins/telegram.ex`

## How it is loaded

This is **not** a separate Mix project. Its `lib` is injected into
`apps/allbert_assist` through `elixirc_paths/1`, so it compiles into that
application; `allbert_plugin.json` is discovery metadata, not a runtime
code-loading instruction. ADR 0098 records why that boundary is a contribution
boundary rather than a compilation one.
