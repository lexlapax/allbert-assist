# allbert.whatsapp — WhatsApp Channel

Shipped source-tree channel plugin for WhatsApp, entered through
`AllbertAssist.Plugins.WhatsApp`.

## Contract

- Plugin id: `allbert.whatsapp` (`kind: "channel"`, version `0.53.0`)
- Channels: `whatsapp`
- Apps: none
- Actions: `whatsapp_doctor`

## Why it is a plugin

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Session windows and template rules constrain when an outbound message is
even permitted.

Registration is inert contract data. Declaring the channel grants no delivery
authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Contents

- `allbert_assist/actions/channels/whatsapp_doctor.ex`
- `allbert_assist/channels/whatsapp/adapter.ex`
- `allbert_assist/channels/whatsapp/client.ex`
- `allbert_assist/channels/whatsapp/doctor.ex`
- `allbert_assist/channels/whatsapp/parser.ex`
- `allbert_assist/channels/whatsapp/renderer.ex`
- `allbert_assist/plugins/whatsapp.ex`
- `allbert_whatsapp/settings/fragment.ex`

## How it is loaded

This is **not** a separate Mix project. Its `lib` is injected into
`apps/allbert_assist` through `elixirc_paths/1`, so it compiles into that
application; `allbert_plugin.json` is discovery metadata, not a runtime
code-loading instruction. ADR 0098 records why that boundary is a contribution
boundary rather than a compilation one.
