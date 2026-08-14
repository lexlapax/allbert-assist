# allbert_tui

The interactive terminal channel as a native umbrella pack, and the operator's
primary interactive surface.

## Contract

- Pack id: `allbert_tui`, `capability_tier: :native`, `registry_order: 1100`
- Catalog `startup_role`: `native_passive`
- Legacy plugin id: `allbert.tui` (`kind: "channel"`, version `0.55.1`)
- Channels: `tui` (`trust_class: :local`, `secret_refs: []`)
- Apps: none
- Actions: none
- CLI group: `allbert admin channels tui`, routed to `AllbertTUI.CLI`

## Why it is its own application

Before v1.4 the code lived under `plugins/allbert.tui/` and was path-injected
into `allbert_assist` through `elixirc_paths/1`, so the plugin boundary was a
contribution boundary and nothing more. M13 created this OTP application, and
**M15.1 finished the job** — see the honest limit below.

The TUI is unlike the other channel packs in one way worth knowing up front: it
is `trust_class: :local` with no external identity, bot token, or secret. Its
one operator per Allbert Home authenticates through the local Attach socket, not
a channel credential. That is why `AllbertTUI.CLI` exists but declares no
subcommands — the group exists so the command path resolves through the same
`AllbertAssist.CLI.PackGroups` mechanism every other channel pack uses, rather
than leaving TUI the one channel with no CLI group at all.

## The extraction is partial, and that is deliberate

M13 moved the pack shell; M15.1 moved the pack's actual subject — about **3,313
lines** with history:

- `AllbertAssist.Runtime.Attach.TUISession`
  (`lib/allbert_assist/runtime/attach/tui_session.ex`)
- `AllbertAssist.CLI.Tui` (`lib/allbert_assist/cli/tui.ex`)
- `AllbertAssist.CLI.Tui.Client` (`lib/allbert_assist/cli/tui/client.ex`)

plus the three suites whose subjects they are. The module names are deliberately
unchanged: `AllbertAssist.Runtime.Attach` is a Tier-2 frozen public contract, and
`rel/overlays/bin/allbert-dispatch` hardcodes `AllbertAssist.CLI.Tui.launch!()`
with no compile error that would catch a rename. Module names are independent of
application names on the BEAM, which is what makes the move legal at all — so do
not read the `AllbertAssist.` prefix on those three files as ownership by
`apps/allbert_assist`.

**Not moved, and this is the honest limit:** `AllbertAssist.Runtime.Attach`,
`AllbertAssist.Runtime.Attach.Server`, and
`AllbertAssist.Runtime.Attach.TUIProtocol` stay in the residual.
`Attach.Server` exists to dispatch residual CLI commands (`CLI.entry_plan/1`,
`CLI.run_attached/1,2`), and `TUIProtocol` has twelve residual references.
Moving either would create an illegal residual-to-pack compile edge, and
removing those references would mean building a session-type registry for a
second consumer that ADR 0091's own non-goals forbid. Kernel ownership was
considered and rejected: the kernel's dependencies are a closed four-package
ledger, and ADR 0098 assigns attach-first selection to composition, not the
kernel.

So: the pack owns its subject and its tests. It is **not** true that no TUI code
remains in the residual, and this README says so rather than claiming a clean
extraction.

The seam that made the move possible is a runtime descriptor lookup. The
compile-time `Attach.Server` alias the moved module used to hold is replaced by a
`session_owner` key on `AllbertTUI.Plugin.channels/0`
(`session_owner: AllbertAssist.Runtime.Attach.TUISession`), resolved lazily at
session start rather than at init. With the pack absent the resolver returns
`nil` and the server returns its existing rejection tuple instead of calling
`nil.start/1`.

## Dependency direction

This pack depends on the kernel (`allbert_kernel`) and the residual
(`allbert_assist`), and on no other pack. Those edges are declared in `mix.exs`
with `in_umbrella: true` and are therefore compile-enforced.

The rule the whole tier model rests on runs the other way: **the kernel must not
depend on any pack**, and a violating edge is a build failure rather than a
review finding. Pack-to-pack edges are permitted when explicit and acyclic;
composition hosts may depend downward on both.

## What is in it

- `AllbertTUI.Pack` — the pack descriptor (`lib/allbert_tui/pack.ex`), declaring
  one settings fragment, one CLI group, and one test-lane owner. `channels/0`
  stays empty deliberately, matching every other channel pack: the real channel
  registry is `AllbertTUI.Plugin.channels/0`, read by
  `AllbertAssist.Plugin.Registry`.
- `AllbertTUI.Plugin` — the ADR 0017 entry point and channel declaration.
- `AllbertTUI.Adapter` — the channel adapter: turn submission, confirmation
  dispatch, cancellation, identity.
- `AllbertTUI.Renderer`, `LiveRegion`, `InputDriver`, `InputReceipt`,
  `EscapeMonitor` — terminal I/O and live rendering.
- `AllbertTUI.SlashCommands` — slash-command routing, including coding sessions.
- `AllbertTUI.Subscriptions`, `AllbertTUI.IdentityBootstrap` — stream and
  identity wiring.
- `AllbertTUI.SettingsFragment` — the pack `FragmentOwner`, derived from
  `AllbertTUI.Settings.Fragment`, which remains the single definition of the
  `channels.tui.*` schema.
- `AllbertTUI.CLI` — the usage-only pack command surface described above.
- `Mix.Tasks.Allbert.Tui` (`lib/mix/tasks/allbert.tui.ex`) — the entry task.

## Effects and readiness

Every effectful path admits a readiness epoch through
`AllbertAssist.Pack.EffectGuard.admit_ready/0` and fails closed with
`:product_not_ready` when it cannot — the private `process_text/3` and
`dispatch_confirmation/4` in `AllbertTUI.Adapter` both do this. A path that
skips admission does not degrade gracefully; it raises on a missing
`:allbert_pack_epoch`. Treat any new effect path here as needing its own
admission.

## How it starts, and how it is discovered

The pack is `native_passive`: `mix.exs` declares no `mod:` application callback
and the pack starts no processes of its own. `allbert_composition` depends on
this application, so it is loaded and started through the normal OTP boot, and
the channel adapter is supervised through the residual's channel supervision as
the `tui` channel descriptor's declared child. The interactive session itself is
started on demand by `Attach.Server` through the `session_owner` lookup above,
or directly by `mix allbert.tui`.

Discovery does not involve a `plugins/` directory; that tree no longer exists.
The descriptor is found through the generated `.app` specification's
`env: [allbert_pack: AllbertTUI.Pack]` entry, reconciled against the sealed
component row in `apps/allbert_assist/priv/licenses/catalog.json`. The retained
`priv/allbert_plugin.json` is a deprecated ADR 0098 §9 alias to that same
descriptor, read from `Application.app_dir/2` by
`AllbertAssist.Plugin.Discovery`, not a second registration.

## Related

- `docs/adr/0098-kernel-application-pack-contract-and-tier-model.md` — the tier
  model and the invariant this application embodies.
- `docs/plans/v1.4-plan.md` §M15.1 — what moved, what did not, and why.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
