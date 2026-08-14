# allbert_signal

The Signal channel as a native umbrella pack: a supervised `signal-cli` daemon,
its adapter, inbound parsing, response/status rendering, and the operator
`doctor` and `link device` actions.

## Contract

- Pack id: `allbert_signal`, `capability_tier: :native`, `registry_order: 900`
- Catalog `startup_role`: `native_effectful`
- Legacy plugin id: `allbert.signal` (`kind: "channel"`, version `0.53.0`)
- Channels: `signal` (`trust_class: :e2ee_origin`)
- Apps: none
- Actions: `AllbertSignal.Actions.Doctor`, `AllbertSignal.Actions.LinkDevice`
- CLI group: `allbert admin channels signal`, routed to `AllbertSignal.CLI`

## Why it is its own application

Every channel is a distinct trust boundary with its own identity model, and
each one is separable so that adding or breaking a transport cannot reach the
others. Signal is the only channel whose `trust_class` is `:e2ee_origin`, and
the only one that requires device linking before any message flows — which is
why this pack contributes a link action alongside its doctor, and why it is the
only channel pack that owns an external OS process.

Before v1.4 that separation was a directory convention: the code lived under
`plugins/allbert.signal/` and was path-injected into `allbert_assist` through
`elixirc_paths/1`, so it was a contribution boundary and nothing more. M13
extracted it into this OTP application, following the template M9 proved with
`notes_files` and M12 with telegram and email. The boundary is now a
compilation boundary the build checks.

Registration is still inert contract data. Declaring the channel grants no
delivery authority by itself: the control credential lives in the vault
(`channels.signal.control_auth_ref`), the channel must be configured and
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

- `AllbertSignal.Pack` — the pack descriptor (`lib/allbert_signal/pack.ex`).
- `AllbertSignal.Plugin` — the ADR 0017 entry point, declaring the channel
  descriptor and the two actions.
- `AllbertSignal.Application` / `AllbertSignal.EffectSupervisor` — the
  activation seam described below.
- `AllbertSignal.Supervisor` — the channel's declared `child_spec`, and the one
  place the two-process shape lives: it supervises `AllbertSignal.Adapter` and
  the owned `signal-cli` daemon. MuonTrap owns daemon process lifetime; JSON
  notification lines are forwarded to the adapter, which remains the only
  inbound runtime boundary.
- `AllbertSignal.Daemon`, `AllbertSignal.Client` — the daemon wrapper and the
  control client.
- `AllbertSignal.Parser`, `AllbertSignal.Renderer` — inbound parsing and
  response/status rendering.
- `AllbertSignal.Doctor`, `AllbertSignal.Actions.Doctor`,
  `AllbertSignal.Actions.LinkDevice` — the operator surface.
- `AllbertSignal.SettingsFragment` — the pack `FragmentOwner`, preserving the
  fragment identity the plugin path used to produce so the move carries no
  settings migration. `AllbertSignal.Settings.Fragment` remains the single
  definition of the schema it derives from.
- `AllbertSignal.CLI` — the pack-owned command surface.

## How it starts, and how it is discovered

`mix.exs` names `mod: {AllbertSignal.Application, []}`, and that application
starts exactly one child: an `AllbertAssist.Pack.ActivationGate` for pack id
`allbert_signal`. The gate subscribes to the kernel Readiness barrier and starts
`AllbertSignal.EffectSupervisor` — and with it `AllbertSignal.Supervisor`, the
adapter, and the daemon — only once the composition coordinator opens readiness.
Until then the application is up and no external process has been spawned, which
is what `native_effectful` means and what matters most for a pack that starts an
OS process.

`EffectSupervisor` runs `one_for_all` with `max_restarts: 0` on purpose: an
effect child is never independently recoverable, because a restart would change
runtime state while the barrier epoch is still live. The gate owns a complete
teardown and a replacement activation instead.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertSignal.Pack]` entry, reconciled against the sealed
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
