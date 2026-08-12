# allbert.tui — Terminal TUI Channel

The interactive terminal channel: `plugin_id` `allbert.tui`, contributing the
`tui` channel and no apps or actions.

## What it is

A shipped source-tree plugin of `kind: "channel"`, entered through
`AllbertTUI.Plugin`. It is the operator's primary interactive surface,
and the largest channel adapter in the tree.

## Contents

- `allbert_assist/plugins/tui.ex` — plugin entrypoint and channel declaration.
- `channels/tui/adapter.ex` — the channel adapter: turn submission, confirmation
  dispatch, cancellation, identity.
- `channels/tui/renderer.ex`, `live_region.ex`, `input_driver.ex`,
  `input_receipt.ex`, `escape_monitor.ex` — terminal I/O and live rendering.
- `channels/tui/slash_commands.ex` — slash-command routing, including coding
  sessions.
- `channels/tui/subscriptions.ex`, `identity_bootstrap.ex` — stream and identity
  wiring.
- `allbert_tui/settings/fragment.ex` — settings schema fragment.
- `mix/tasks/allbert.tui.ex` — the entry task.

## Effects and readiness

Every effectful path admits a readiness epoch through
`EffectGuard.admit_ready/0` and fails closed with `:product_not_ready` when it
cannot — `process_text/3` and `dispatch_confirmation/4` both do this. A path
that skips admission does not degrade gracefully, it raises on a missing
`:allbert_pack_epoch`; treat any new effect path here as needing its own
admission.

## How it is loaded

Not a separate Mix project. Its `lib` is injected into `apps/allbert_assist`
through `elixirc_paths/1`; `allbert_plugin.json` is discovery metadata only.
