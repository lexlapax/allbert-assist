# allbert.matrix — Matrix Channel

Shipped source-tree channel plugin for Matrix, entered through
`AllbertAssist.Plugins.Matrix`.

## Contract

- Plugin id: `allbert.matrix` (`kind: "channel"`, version `0.53.0`)
- Channels: `matrix`
- Apps: none
- Actions: `matrix_doctor`

## Why it is a plugin

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Federated rooms make room membership, not the account, the unit of trust.

Registration is inert contract data. Declaring the channel grants no delivery
authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Contents

- `allbert_assist/channels/matrix/adapter.ex`
- `allbert_assist/channels/matrix/client.ex`
- `allbert_assist/channels/matrix/doctor.ex`
- `allbert_assist/channels/matrix/parser.ex`
- `allbert_assist/channels/matrix/renderer.ex`
- `allbert_assist/plugins/matrix.ex`
- `allbert_matrix/settings/fragment.ex`

## How it is loaded

This is **not** a separate Mix project. Its `lib` is injected into
`apps/allbert_assist` through `elixirc_paths/1`, so it compiles into that
application; `allbert_plugin.json` is discovery metadata, not a runtime
code-loading instruction. ADR 0098 records why that boundary is a contribution
boundary rather than a compilation one.
