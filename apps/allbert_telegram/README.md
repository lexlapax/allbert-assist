# allbert_telegram

The second umbrella pack extracted from a shipped plugin, and the first to own
its own CLI surface. It provides the Telegram channel: long-poll delivery,
inbound parsing, response/status/media rendering, and an operator-facing
`doctor` diagnostic.

## Why this exists

v1.4 M9 extracted `notes_files` first and established the pack-extraction
template. M12 applies that template to the channel plugins, starting with
Telegram: the implementation modules move out of
`AllbertAssist.Channels.Telegram.*` into this application's own
`AllbertTelegram.*` namespace, and settings ownership moves from the plugin
path to a pack `FragmentOwner`, the same way M9 proved for notes_files.

Telegram differs from notes_files in one structural way: before extraction,
the residual's `allbert admin channels telegram ...` CLI routes called
`Telegram.Adapter`/`Telegram.Renderer` through compile-time aliases that only
compiled because the plugin source was path-injected into the residual. After
extraction that would be a forbidden residual-to-pack return edge, so the
command surface moves to this application too — `AllbertTelegram.Pack` is the
first non-empty `cli_groups/0` implementation in the tree.

## The invariant

**This pack must not depend on any other pack.** It may depend on the kernel
(`allbert_kernel`) and the residual (`allbert_assist`) — the same pair
notes_files takes. Its dependencies are declared in `mix.exs` and
compile-enforced: a circular edge fails the build and reveals the error before
runtime.

Pack-to-pack dependencies are permitted when explicit and acyclic; only
kernel-to-pack is forbidden. Composition hosts may depend on both.

## What is in it

- **`AllbertTelegram.Pack`** — the pack descriptor, declaring one settings
  fragment and one CLI group, with `registry_order: 300` to slot after kernel
  (`0`), residual (`100`), and notes_files (`200`).
- **`AllbertTelegram.Plugin`** — the channel entry point (`use
  AllbertAssist.Plugin`), declaring the `telegram` channel descriptor
  (adapter, secret refs, primitives, threading, streaming) and the `doctor`
  action. `settings_schema/0` returns `[]`; see `SettingsFragment` below for
  why.
- **`AllbertTelegram.SettingsFragment`** — a pack `FragmentOwner` preserving
  `id: "plugin:allbert.telegram"` / `owner: "allbert.telegram"` /
  `source: :plugin` / `group: :plugins`, so the move carries no settings
  migration. It declares exactly the 3 `channels.telegram.autonomous_notify.*`
  keys that ever reached the composed schema; the base
  `channels.telegram.enabled` / `channels.telegram.bot_token_ref` keys the
  plugin used to also declare never composed (no `:default`) and are owned,
  with defaults, by the core `AllbertAssist.Settings.FragmentOwners.Channels`
  fragment instead.
- **`AllbertTelegram.Adapter`** — the long-poll receive loop and outbound
  dispatch/edit implementation.
- **`AllbertTelegram.Client`** — the Bot API HTTP client.
- **`AllbertTelegram.Parser`** — inbound update parsing.
- **`AllbertTelegram.Renderer`** — response/status/media rendering, including
  redacted media-output fallbacks.
- **`AllbertTelegram.Doctor`** / **`AllbertTelegram.Actions.Doctor`** — the
  operator diagnostic action.

The manifest lives at `priv/allbert_plugin.json`.

## How it starts

`allbert_composition` depends on this application, so the OTP supervisor chain
starts it through the normal application boot. The channel adapter is a real
process (the long-poll loop), unlike notes_files' `native_passive` pack.

## Related

- `docs/adr/0098-kernel-application-pack-contract-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/allbert_notes_files/README.md` — the extraction template this pack
  reuses.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
