# TUI Channel Operator Guide

Status: shipped in v0.55.0. This guide covers the shipped terminal channel
descriptor, basic `mix allbert.tui` launcher, identity mapping, split-payload
rendering seam, typed approval rendering/resolution, warm TUI validation, and the
deterministic `release.v055` gate.
The full release-validation checklist is
`docs/plans/v0.55-request-flow.md#operator-validation-punchlist-v055-persistent-tui-session`.

## Requirements

- A local terminal that can run Mix tasks.
- A disposable `ALLBERT_HOME` for validation when testing release behavior.
- A mapped terminal profile. The default profile is `"default"` and must be
  mapped through `channels.tui.identity_map`; the terminal never implicitly
  claims `"local"`.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-tui.XXXXXX)"
mix allbert.ecto.migrate --quiet

mix allbert.settings set channels.tui.identity_map '[{"external_user_id":"default","user_id":"local","enabled":true}]'
mix allbert.settings get channels.tui.identity_map
mix allbert.settings set channels.tui.enabled true
mix allbert.settings get channels.tui.enabled
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

The launcher boots the app with TUI-specific `Channels.Supervisor` child options
and waits on the supervised TUI child. Completed responses render into normal
terminal scrollback. Transient status output may appear while a turn is running,
but it detaches before the next prompt; the actual input prompt remains the only
`allbert:default>` line. Type `/quit` or `/exit` to stop the launcher.
Plain settings/channel inspection tasks may start the supervised descriptor child
when `channels.tui.enabled` is true, but that child is non-interactive and quiet;
only `mix allbert.tui` enables the live input loop and banner.

`mix allbert.tui` keeps the live terminal readable by default: startup
plugin/query chatter is suppressed, app logs below warning stay quiet after
startup, and Ecto query debug logs are disabled. To turn post-start diagnostic
logs back on for a specific run:

```sh
ALLBERT_TUI_LOG_LEVEL=debug mix allbert.tui
```

To suppress even warnings while checking the prompt/rendering path:

```sh
ALLBERT_TUI_LOG_LEVEL=none mix allbert.tui
```

## Verify

Run the deterministic focused tests before live validation:

```sh
MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/channels/tui_test.exs
MIX_ENV=test mix test apps/allbert_assist/test/allbert_assist/runtime_test.exs
MIX_ENV=test mix test apps/allbert_assist/test/security/v055_tui_channel_eval_test.exs
ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test release.v055
```

`ALLBERT_TEST_KEEP_TMP=1` keeps the release gate's owned temporary home so the
printed `release.v055 evidence:` path remains readable after the Mix task exits.

## v0.55.1 Warm Console Standard

v0.55.1 (`docs/plans/v0.55b-request-flow.md`) hardens this same TUI into the
persistent operator/validation console. The go-forward interactive validation
standard is:

- run the deterministic `mix allbert.test release.v0551` gate first;
- prepare a fresh `ALLBERT_HOME`, migrate it with `mix allbert.ecto.migrate
  --quiet`, configure `channels.tui.identity_map`, enable `channels.tui.enabled`,
  and preflight the Notes/files `write_note` route before launch;
- launch one transcript-captured `mix allbert.tui` session and keep it open for
  the whole manual punchlist;
- issue operator inspections through the in-session slash commands only:
  `/status`, `/confirmations`, `/events`, `/channels`, `/settings get`, and
  `/help`;
- do not use cold `mix allbert.ask` or cold `mix allbert.*` inspection commands
  between in-session checks;
- retain the redacted transcript and the `release.v0551` evidence path outside
  disposable `/tmp` state for M6 closeout.

`mix allbert.channels status` is the cold-task twin for deterministic parity and
source-of-truth evidence; it is not a manual in-session substitute for `/channels`
inside the v0.55.1 punchlist.

Manual M2 smoke:

- Start `mix allbert.tui` with the mapped identity.
- Type a normal prompt and confirm the response appears as scrollback while the
  same prompt remains live.
- Exit with `/quit`, empty `channels.tui.identity_map`, relaunch the same
  `ALLBERT_HOME`, and confirm the same terminal input is rejected without an
  assistant response.
- Restore the identity map before continuing to later M3/M5 validation.

Manual M3 approval smoke:

- Trigger an action that returns `status: :needs_confirmation`.
- Confirm the TUI prints exact typed commands plus numbered options:
  `ALLBERT:APPROVE:<id>`, `ALLBERT:DENY:<id>`, and `ALLBERT:SHOW:<id>`.
- Type one exact approval command at the same prompt.
- Confirm the resolution result is printed and `mix allbert.confirmations list`
  shows the confirmation resolved for channel `tui`.
- Confirm no button/link affordance or target URL is printed in the terminal
  approval handoff.

Split-payload rule: runtime conversation history stores `model_payload`; terminal
renderers draw `surface_payload`. Terminal framing, ANSI styling, paging hints, or
LiveScreen prompt text must not be stored as model-facing conversation content.

v0.55 closeout note: the operator accepted the warm TUI A1-A5 validation on
2026-06-22. The separate Matrix live provider smoke is not TUI validation and is
recorded as blocked by inactive Matrix credentials until the operator refreshes
the provider token.

## Cleanup

Disable `channels.tui.enabled` in any temporary validation home and keep release
evidence only under the selected `ALLBERT_HOME`.
