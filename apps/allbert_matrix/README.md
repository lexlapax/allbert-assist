# allbert_matrix

The Matrix channel as a native umbrella pack: room sync, inbound parsing,
response/status rendering, and an operator-facing `doctor` diagnostic.

## Contract

- Pack id: `allbert_matrix`, `capability_tier: :native`, `registry_order: 800`
- Catalog `startup_role`: `native_effectful`
- Legacy plugin id: `allbert.matrix` (`kind: "channel"`, version `0.53.0`)
- Channels: `matrix` (`trust_class: :server_readable`)
- Apps: none
- Actions: `AllbertMatrix.Actions.Doctor`
- CLI group: `allbert admin channels matrix`, routed to `AllbertMatrix.CLI`

## Why it is its own application

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Federated rooms make room membership, not the account, the unit of
trust.

Before v1.4 that separation was a directory convention: the code lived under
`plugins/allbert.matrix/` and was path-injected into `allbert_assist` through
`elixirc_paths/1`, so it was a contribution boundary and nothing more. M13
extracted it into this OTP application, following the template M9 proved with
`notes_files` and M12 with telegram and email. The boundary is now a
compilation boundary the build checks.

Registration is still inert contract data. Declaring the channel grants no
delivery authority by itself: the access token lives in the vault
(`channels.matrix.access_token_ref`), the channel must be configured and
enabled through Settings Central, and inbound identity is mapped before a turn
is admitted.

## Dependency direction

This pack depends on the kernel (`allbert_kernel`) and the residual
(`allbert_assist`), and on no other pack. Those edges are declared in `mix.exs`
with `in_umbrella: true` and are therefore compile-enforced.

The rule the whole tier model rests on runs the other way: **the kernel must not
depend on any pack**, and a violating edge is a build failure rather than a
review finding. Pack-to-pack edges are permitted when explicit and acyclic;
composition hosts may depend downward on both.

## What is in it

- `AllbertMatrix.Pack` — the pack descriptor (`lib/allbert_matrix/pack.ex`).
- `AllbertMatrix.Plugin` — the ADR 0017 entry point, declaring the channel
  descriptor and the doctor action.
- `AllbertMatrix.Application` / `AllbertMatrix.EffectSupervisor` — the
  activation seam described below.
- `AllbertMatrix.Adapter` — the channel's supervised child: sync loop and
  outbound delivery.
- `AllbertMatrix.Client` — the client-server API client.
- `AllbertMatrix.Parser`, `AllbertMatrix.Renderer` — inbound parsing and
  response/status rendering.
- `AllbertMatrix.Doctor`, `AllbertMatrix.Actions.Doctor` — the operator
  diagnostic.
- `AllbertMatrix.SettingsFragment` — the pack `FragmentOwner`, preserving the
  fragment identity the plugin path used to produce so the move carries no
  settings migration. `AllbertMatrix.Settings.Fragment` remains the single
  definition of the schema it derives from.
- `AllbertMatrix.CLI` — the pack-owned command surface.

## How it starts, and how it is discovered

`mix.exs` names `mod: {AllbertMatrix.Application, []}`, and that application
starts exactly one child: an `AllbertAssist.Pack.ActivationGate` for pack id
`allbert_matrix`. The gate subscribes to the kernel Readiness barrier and starts
`AllbertMatrix.EffectSupervisor` — and with it `AllbertMatrix.Adapter` — only
once the composition coordinator opens readiness. Until then the application is
up and the transport is dormant, which is what `native_effectful` means.

`EffectSupervisor` runs `one_for_all` with `max_restarts: 0` on purpose: an
effect child is never independently recoverable, because a restart would change
runtime state while the barrier epoch is still live. The gate owns a complete
teardown and a replacement activation instead.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertMatrix.Pack]` entry, reconciled against the sealed
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
