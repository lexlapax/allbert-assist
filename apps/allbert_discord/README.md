# allbert_discord

The Discord channel as a native umbrella pack: gateway session, inbound
parsing, response/status rendering, and an operator-facing `doctor` diagnostic.

## Contract

- Pack id: `allbert_discord`, `capability_tier: :native`, `registry_order: 700`
- Catalog `startup_role`: `native_effectful`
- Legacy plugin id: `allbert.discord` (`kind: "channel"`, version `0.52.0`)
- Channels: `discord` (`trust_class: :server_readable`)
- Apps: none
- Actions: `AllbertDiscord.Actions.Doctor`
- CLI group: `allbert admin channels discord`, routed to `AllbertDiscord.CLI`

## Why it is its own application

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. A persistent gateway socket means the adapter must survive reconnects
without replaying already-processed events.

Before v1.4 that separation was a directory convention: the code lived under
`plugins/allbert.discord/` and was path-injected into `allbert_assist` through
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

- `AllbertDiscord.Pack` — the pack descriptor (`lib/allbert_discord/pack.ex`).
- `AllbertDiscord.Plugin` — the ADR 0017 entry point, declaring the channel
  descriptor and the doctor action.
- `AllbertDiscord.Application` / `AllbertDiscord.EffectSupervisor` — the
  activation seam described below.
- `AllbertDiscord.Adapter` — inbound dispatch and outbound delivery.
- `AllbertDiscord.Client`, `Client.GatewayPort` and its `Real` / `Stub`
  implementations — the gateway seam, so release tests never need a live socket.
- `AllbertDiscord.Parser`, `AllbertDiscord.Renderer` — inbound parsing and
  response/status rendering.
- `AllbertDiscord.Doctor`, `AllbertDiscord.Actions.Doctor` — the operator
  diagnostic.
- `AllbertDiscord.SettingsFragment` — the pack `FragmentOwner`, preserving the
  fragment identity the plugin path used to produce so the move carries no
  settings migration. `AllbertDiscord.Settings.Fragment` remains the single
  definition of the schema it derives from.
- `AllbertDiscord.CLI` — the pack-owned command surface.

## How it starts, and how it is discovered

`mix.exs` names `mod: {AllbertDiscord.Application, []}`, and that application
starts exactly one child: an `AllbertAssist.Pack.ActivationGate` for pack id
`allbert_discord`. The gate subscribes to the kernel Readiness barrier and
starts `AllbertDiscord.EffectSupervisor` — and with it the adapter — only once
the composition coordinator opens readiness. Until then the application is up
and the transport is dormant, which is what `native_effectful` means.

`EffectSupervisor` runs `one_for_all` with `max_restarts: 0` on purpose: an
effect child is never independently recoverable, because a restart would change
runtime state while the barrier epoch is still live. The gate owns a complete
teardown and a replacement activation instead.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertDiscord.Pack]` entry, reconciled against the sealed
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
