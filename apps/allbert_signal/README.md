# allbert.signal — Signal Channel

Shipped source-tree channel plugin for Signal, entered through
`AllbertSignal.Plugin`.

## Contract

- Plugin id: `allbert.signal` (`kind: "channel"`, version `0.53.0`)
- Channels: `signal`
- Apps: none
- Actions: `signal_doctor`, `signal_link_device`

## Why it is a plugin

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Signal requires device linking before any message flows, which is why
this plugin contributes a link action alongside its doctor.

Registration is inert contract data. Declaring the channel grants no delivery
authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Contents

- `allbert_assist/actions/channels/signal_doctor.ex`
- `allbert_assist/actions/channels/signal_link_device.ex`
- `allbert_assist/channels/signal/adapter.ex`
- `allbert_assist/channels/signal/client.ex`
- `allbert_assist/channels/signal/daemon.ex`
- `allbert_assist/channels/signal/doctor.ex`
- `allbert_assist/channels/signal/parser.ex`
- `allbert_assist/channels/signal/renderer.ex`
- `allbert_assist/channels/signal/supervisor.ex`
- `allbert_assist/plugins/signal.ex`

## How it is loaded

This is **not** a separate Mix project. Its `lib` is injected into
`apps/allbert_assist` through `elixirc_paths/1`, so it compiles into that
application; `allbert_plugin.json` is discovery metadata, not a runtime
code-loading instruction. ADR 0098 records why that boundary is a contribution
boundary rather than a compilation one.
