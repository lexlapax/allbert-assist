# TUI Channel Operator Guide

Status: v0.55 M2 implemented. This guide covers the shipped terminal channel
descriptor, basic `mix allbert.tui` launcher, identity mapping, and split-payload
rendering seam. Approval rendering and typed approval resolution are M3 scope.

## Requirements

- A local terminal that can run Mix tasks.
- A disposable `ALLBERT_HOME` for validation when testing release behavior.
- A mapped terminal profile. The default profile is `"default"` and must be
  mapped through `channels.tui.identity_map`; the terminal never implicitly
  claims `"local"`.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-tui.XXXXXX)"
mix ecto.migrate.allbert --quiet

mix allbert.settings set channels.tui.enabled true
mix allbert.settings set channels.tui.identity_map '[{"external_user_id":"default","user_id":"local","enabled":true}]'
mix allbert.settings get channels.tui.identity_map
```

Check the descriptor-derived channel summary and parity matrix:

```sh
mix allbert.channels show tui
mix allbert.channels --parity
```

Expected summary: channel `tui`, provider `terminal`, identity-map key
`channels.tui.identity_map`, primitives `typed_command+list`, threading `rich`,
and no secrets.

## Run

```sh
mix allbert.tui
```

The launcher boots the app and starts a persistent Owl input loop for the terminal
channel. Completed responses render into normal terminal scrollback; the adapter
uses a single `Owl.LiveScreen` status block for the active prompt/status line.
Type `/quit` or `/exit` to stop the launcher.

## Verify

Run the deterministic M2 focused tests before live validation:

```sh
MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/channels/tui_test.exs
MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/runtime_test.exs
```

Manual M2 smoke:

- Start `mix allbert.tui` with the mapped identity.
- Type a normal prompt and confirm the response appears as scrollback while the
  same prompt remains live.
- Empty `channels.tui.identity_map`, restart the launcher if needed, and confirm
  the same terminal input is rejected without an assistant response.
- Restore the identity map before continuing to later M3/M5 validation.

Split-payload rule: runtime conversation history stores `model_payload`; terminal
renderers draw `surface_payload`. Terminal framing, ANSI styling, paging hints, or
LiveScreen prompt text must not be stored as model-facing conversation content.

## Cleanup

Disable `channels.tui.enabled` in any temporary validation home and keep release
evidence only under the selected `ALLBERT_HOME`.
