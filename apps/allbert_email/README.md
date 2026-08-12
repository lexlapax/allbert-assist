# allbert.email — Email Channel

Shipped source-tree channel plugin for Email, entered through
`AllbertEmail.Plugin`.

## Contract

- Plugin id: `allbert.email` (`kind: "channel"`, version `0.17.0`)
- Channels: `email`
- Apps: none
- Actions: none. The channel is delivery only.

## Why it is a plugin

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Mail is the only channel where the transport is a mailbox the operator
also uses by hand, so identity mapping and reply threading carry the risk here.

Registration is inert contract data. Declaring the channel grants no delivery
authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Contents

- `allbert_assist/channels/email/adapter.ex`
- `allbert_assist/channels/email/doctor.ex`
- `allbert_assist/channels/email/imap_client.ex`
- `allbert_assist/channels/email/parser.ex`
- `allbert_assist/channels/email/renderer.ex`
- `allbert_assist/channels/email/smtp_client.ex`
- `allbert_assist/plugins/email.ex`

## How it is loaded

This is **not** a separate Mix project. Its `lib` is injected into
`apps/allbert_assist` through `elixirc_paths/1`, so it compiles into that
application; `allbert_plugin.json` is discovery metadata, not a runtime
code-loading instruction. ADR 0098 records why that boundary is a contribution
boundary rather than a compilation one.
