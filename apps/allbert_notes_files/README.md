# allbert_notes_files

The first umbrella pack extracted from a shipped plugin. It provides local
file search, read, and write actions bounded to a configured notes root,
with the read-only actions delegating path/extension/size enforcement to
`PermissionGate` and write actions creating durable confirmation records.

## Why this exists

Before v1.4, every shipped capability compiled into `allbert_assist`. M9 of
v1.4 extracted the `notes_files` capability into its own umbrella application,
proving the pack extraction template and that settings ownership moves preserve
stored identity without requiring a migration engine. It is the smallest of the
three extraction candidates and already the only plugin exercising genuine
external settings ownership.

In v1.2, telegram and email reuse this extraction pattern and the settings
ownership model established here.

## The invariant

**This pack must not depend on any other pack.** It may depend on the kernel
(`allbert_kernel`). Its dependencies are declared in `mix.exs` and compile-enforced:
a circular edge fails the build and reveals the error before runtime.

Pack-to-pack dependencies are permitted when explicit and acyclic; only
kernel-to-pack is forbidden. Composition hosts may depend on both.

## What is in it

- **`AllbertNotesFiles.Pack`** — the pack descriptor, declaring two settings
  fragments and three actions (`SearchNotes`, `ReadNote`, `WriteNote`) with
  `registry_order: 200` to slot after kernel (`0`) and residual (`100`).
- **`AllbertNotesFiles.App`** — the app entrypoint, using
  `AllbertAssist.App.SurfaceProvider` and declaring `:notes_files` as the
  app id, memory namespace, and settings owner.
- **`AllbertNotesFiles.Actions`** — three registered actions:
  - `search_notes` — bounded search over notes in the configured root.
  - `read_note` — bounded read of a single note file.
  - `write_note` — durable-confirmation-gated write to a single note file.
- **`AllbertNotesFiles.SettingsFragment`** — a pack `FragmentOwner` declaring
  two settings:
  - `apps.notes_files.notes_root` (default: `<ALLBERT_HOME>/notes`)
  - `apps.notes_files.max_results` (default: `25`)
- **`AllbertNotesFiles.Notes`** — internal read/write/search primitives bounded
  by root, extension, and size checks.

The manifest and skill entries live in `priv/allbert_plugin.json` and
`priv/skills/` respectively.

## How it starts

`allbert_composition` depends on this application, so the OTP supervisor chain
starts it through the normal application boot. The pack declares no processes:
it is `native_passive` and contributes registration data and actions only.

The `:notes_files` memory namespace declaration is read-only by design. Note
files are not promoted to Allbert memory automatically; memory promotion
remains a separate confirmed memory action.

## Related

- `docs/adr/0098-kernel-application-pack-contract-tier-model.md` — the tier
  model and the invariant this application embodies.
- `apps/allbert_kernel/README.md` — the contracts and mechanisms every pack
  depends on.
- `apps/allbert_composition/README.md` — the host that assembles the kernel
  and packs into one running product.
