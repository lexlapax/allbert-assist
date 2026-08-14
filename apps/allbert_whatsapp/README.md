# allbert_whatsapp

The WhatsApp channel as a native umbrella pack: outbound delivery through the
Cloud API, inbound parsing, response/status rendering, and an operator-facing
`doctor` diagnostic.

## Contract

- Pack id: `allbert_whatsapp`, `capability_tier: :native`, `registry_order: 1200`
- Catalog `startup_role`: `native_effectful`
- Legacy plugin id: `allbert.whatsapp` (`kind: "channel"`, version `0.53.0`)
- Channels: `whatsapp` (`trust_class: :server_readable`)
- Apps: none
- Actions: `AllbertWhatsApp.Actions.Doctor`
- CLI group: `allbert admin channels whatsapp`, routed to `AllbertWhatsApp.CLI`

## Why it is its own application

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Session windows and template rules constrain when an outbound message is
even permitted, so the rules about *when* Allbert may speak are denser here than
on any other channel.

Inbound arrives over a webhook the web application routes, not over a socket
this pack owns — which is why the pack declares three secret refs
(`channels.whatsapp.access_token_ref`, `.app_secret_ref`,
`.webhook_verify_token_ref`) where most channels declare one.

Before v1.4 that separation was a directory convention: the code lived under
`plugins/allbert.whatsapp/` and was path-injected into `allbert_assist` through
`elixirc_paths/1`, so it was a contribution boundary and nothing more. M13
extracted it into this OTP application, following the template M9 proved with
`notes_files` and M12 with telegram and email. The boundary is now a
compilation boundary the build checks.

Registration is still inert contract data. Declaring the channel grants no
delivery authority by itself: credentials live in the vault, the channel must be
configured and enabled through Settings Central, and inbound identity is mapped
before a turn is admitted.

## Dependency direction

This pack depends on the kernel (`allbert_kernel`) and the residual
(`allbert_assist`), and on no other pack. Those edges are declared in `mix.exs`
with `in_umbrella: true` and are therefore compile-enforced.

The rule the whole tier model rests on runs the other way: **the kernel must not
depend on any pack**, and a violating edge is a build failure rather than a
review finding. Pack-to-pack edges are permitted when explicit and acyclic;
composition hosts may depend downward on both.

## What is in it

- `AllbertWhatsApp.Pack` — the pack descriptor (`lib/allbert_whatsapp/pack.ex`).
- `AllbertWhatsApp.Plugin` — the ADR 0017 entry point, declaring the channel
  descriptor and the doctor action.
- `AllbertWhatsApp.Application` / `AllbertWhatsApp.EffectSupervisor` — the
  activation seam described below.
- `AllbertWhatsApp.Adapter` — the channel's supervised child: inbound dispatch
  and outbound delivery.
- `AllbertWhatsApp.Client` — the Cloud API client.
- `AllbertWhatsApp.Parser`, `AllbertWhatsApp.Renderer` — inbound parsing and
  response/status rendering.
- `AllbertWhatsApp.Doctor`, `AllbertWhatsApp.Actions.Doctor` — the operator
  diagnostic.
- `AllbertWhatsApp.SettingsFragment` — the pack `FragmentOwner`, preserving the
  fragment identity the plugin path used to produce so the move carries no
  settings migration. `AllbertWhatsApp.Settings.Fragment` remains the single
  definition of the schema it derives from.
- `AllbertWhatsApp.CLI` — the pack-owned command surface.

The inbound webhook controller is **not** here: it is
`AllbertAssistWeb.PublicProtocol.WhatsAppWebhookController` in
`allbert_assist_web`, because a route belongs to the application that owns the
router. A pack does not reach up into Web.

## How it starts, and how it is discovered

`mix.exs` names `mod: {AllbertWhatsApp.Application, []}`, and that application
starts exactly one child: an `AllbertAssist.Pack.ActivationGate` for pack id
`allbert_whatsapp`. The gate subscribes to the kernel Readiness barrier and
starts `AllbertWhatsApp.EffectSupervisor` — and with it
`AllbertWhatsApp.Adapter` — only once the composition coordinator opens
readiness. Until then the application is up and the transport is dormant, which
is what `native_effectful` means.

`EffectSupervisor` runs `one_for_all` with `max_restarts: 0` on purpose: an
effect child is never independently recoverable, because a restart would change
runtime state while the barrier epoch is still live. The gate owns a complete
teardown and a replacement activation instead.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertWhatsApp.Pack]` entry, reconciled against the sealed
component row in `apps/allbert_assist/priv/licenses/catalog.json`. The retained
`priv/allbert_plugin.json` is a deprecated ADR 0098 §9 alias to that same
descriptor, read from `Application.app_dir/2` by
`AllbertAssist.Plugin.Discovery`, not a second registration.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/allbert_telegram/README.md` — the channel extraction this pack follows.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
