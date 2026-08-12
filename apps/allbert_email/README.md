# allbert_email

The third umbrella pack extracted from a shipped plugin, following the
templates `notes_files` (M9) and `telegram` (M12) established. It provides the
Email channel: IMAP polling, SMTP delivery, inbound parsing, response
rendering, and an operator-facing `doctor` diagnostic.

## Why this exists

M12 applies the M9 pack-extraction template to the channel plugins. The
implementation modules move out of `AllbertAssist.Channels.Email.*` into this
application's own `AllbertEmail.*` namespace, and settings ownership moves
from the plugin path to a pack `FragmentOwner` — the same move
`AllbertTelegram.SettingsFragment` made.

Email is the one channel where the transport is a mailbox the operator also
uses by hand, so identity mapping and reply threading carry the most risk
here; that risk lives in `AllbertEmail.Adapter` and `AllbertEmail.Parser`
unchanged by the extraction.

Like telegram, this pack owns its own CLI surface
(`allbert admin channels email ...`) rather than the residual calling back
into it, which would be a forbidden residual-to-pack return edge.

## The invariant

**This pack must not depend on any other pack.** It may depend on the kernel
(`allbert_kernel`) and the residual (`allbert_assist`) — the same pair
notes_files and telegram take. Its dependencies are declared in `mix.exs` and
compile-enforced: a circular edge fails the build and reveals the error before
runtime.

Pack-to-pack dependencies are permitted when explicit and acyclic; only
kernel-to-pack is forbidden. Composition hosts may depend on both.

`gen_smtp` is a dependency of this application, not the residual: a
repo-wide search found `AllbertEmail.SmtpClient` as its only caller, so the
dependency moved with the code that uses it. `swoosh` stays a residual/web
dependency — `AllbertAssist.Mailer` and `allbert_assist_web` use it
independently of this channel, so it did not move.

## What is in it

- **`AllbertEmail.Pack`** — the pack descriptor, declaring one settings
  fragment and one CLI group, with `registry_order: 400` to slot after kernel
  (`0`), residual (`100`), notes_files (`200`), and telegram (`300`).
- **`AllbertEmail.Plugin`** — the channel entry point (`use
  AllbertAssist.Plugin`), declaring the `email` channel descriptor (adapter,
  secret refs, primitives, threading) and the `doctor` action.
  `settings_schema/0` returns `[]`; see `SettingsFragment` below for why.
- **`AllbertEmail.SettingsFragment`** — a pack `FragmentOwner` preserving
  `id: "plugin:allbert.email"` / `owner: "allbert.email"` / `source: :plugin`
  / `group: :plugins`, so the move carries no settings migration. It declares
  exactly the 3 `channels.email.autonomous_notify.*` keys that ever reached
  the composed schema (with `level`'s `allowed_values` narrowed to
  `["completion"]`, since email has no attached-surface concept). The base
  `channels.email.enabled` / `channels.email.imap_password_ref` /
  `channels.email.smtp_password_ref` keys the plugin used to also declare
  never composed (no `:default`) and are owned, with defaults, by the core
  `AllbertAssist.Settings.FragmentOwners.Channels` fragment instead.
- **`AllbertEmail.Adapter`** — the IMAP poll loop and outbound send
  implementation.
- **`AllbertEmail.ImapClient`** — the IMAP client.
- **`AllbertEmail.SmtpClient`** — the SMTP client, built on `gen_smtp`.
- **`AllbertEmail.Parser`** — inbound message parsing.
- **`AllbertEmail.Renderer`** — response rendering, including approval-handoff
  subjects and bodies.
- **`AllbertEmail.Doctor`** / **`AllbertEmail.Actions.Doctor`** — the operator
  diagnostic action.

The manifest lives at `priv/allbert_plugin.json`.

## How it starts

`allbert_composition` depends on this application, so the OTP supervisor chain
starts it through the normal application boot. The channel adapter is a real
process (the IMAP poll loop), unlike notes_files' `native_passive` pack.

## Related

- `docs/adr/0098-kernel-application-pack-contract-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/allbert_telegram/README.md` — the sibling channel extraction this pack
  mirrors most closely.
- `apps/allbert_notes_files/README.md` — the original extraction template.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
