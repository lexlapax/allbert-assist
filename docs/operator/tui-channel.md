# TUI Channel Operator Guide

Status: shipped in v0.55.0. This guide covers the shipped terminal channel
descriptor, basic `mix allbert.tui` launcher, identity mapping, split-payload
rendering seam, typed approval rendering/resolution, warm TUI validation, and the
deterministic `release.v055` gate. v0.56 extends the same warm console with
read-only `/intents` and `/models` validation views.
v1.2 adds a bounded fresh-Home activation-and-identity bootstrap for the
built-in local interactive launchers; the historical explicit-map posture
remains binding for custom or generic adapter startup.
The full release-validation checklist is
`docs/plans/archives/v0.55-request-flow.md#operator-validation-punchlist-v055-persistent-tui-session`.

## Requirements

- A local terminal that can run Mix tasks.
- A disposable `ALLBERT_HOME` for validation when testing release behavior.
- The built-in `default` profile. On a fresh Home, packaged `allbert tui` and
  development `mix allbert.tui` atomically persist
  `channels.tui.enabled=true` and the ordinary list-shaped `default → local`
  Settings mapping before the adapter starts. Custom profiles and direct/generic
  adapter startup are never auto-mapped. Any raw-present identity map is sticky.

## Configure

```sh
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-tui.XXXXXX)"
mix allbert.ecto.migrate --quiet
```

The first launch needs no identity setup command. At the first prompt, use
`/settings get channels.tui.enabled` and
`/settings get channels.tui.identity_map` to confirm both durable entries. The
TUI remains available whether or not onboarding has run; this launcher bootstrap
does not complete, skip, or otherwise mutate onboarding. A restart of the same
Home preserves both settings and creates no second launcher-bootstrap audit.

For a custom profile/user mapping, or to make operator intent explicit, set the
full list before launch:

```sh
mix allbert.settings set channels.tui.identity_map \
  '[{"external_user_id":"work","user_id":"alice","enabled":true}]'
mix allbert.settings set channels.tui.profile work
mix allbert.settings get channels.tui.identity_map
```

An explicitly stored empty map or disabled entry is sticky and is not repaired
by launch. Ordinary input then prints one of these bounded explanations and
never reaches Runtime:

```text
Message not sent: terminal profile is not mapped to an Allbert user. Configure channels.tui.identity_map.
Message not sent: terminal profile mapping is disabled.
```

Set the intended full map through Settings Central to re-enable admission. A
raw `channels.tui.enabled=false` is also authoritative: the interactive launcher
exits before adapter startup and does not rewrite either setting. Re-enable it
with the command for the launcher being used:

```sh
allbert admin settings set channels.tui.enabled true
mix allbert.settings set channels.tui.enabled true
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
and waits on the supervised TUI child. Both launchers use the same sequence:
boot registries, atomically persist the raw-absent activation and built-in
identity entries, then start the adapter so its settings snapshot contains both.
Completed responses render into normal
terminal scrollback. Streaming progress also uses transcript-stable, coalesced
scrollback by default rather than erased live-screen blocks, so captured validation
transcripts do not retain blank repaint gaps or per-token progress spam. The actual
input prompt remains the only
`allbert:default>` line. Type `/quit` or `/exit` to stop the launcher.
Plain settings/channel inspection tasks may start the supervised descriptor child
when `channels.tui.enabled` is true, but that child is non-interactive and quiet;
only `mix allbert.tui` enables the live input loop and banner.

The base TUI is line-oriented by design: typed turns, slash commands, approval
handoffs, and transcript capture operate on complete lines. Pi-mode's single-key
Esc cancellation is a v0.57 input-driver extension layered on the same channel;
it is not evidence that the v0.55 scrollback-native TUI needs a full-screen or
alternate-screen rewrite.

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

`ALLBERT_TUI_LOG_LEVEL` controls application diagnostics, not Allbert's
operator-facing lifecycle output. Lines such as `[fan-out] run started`,
`run progress`, and `fanout joined` are product status from an attached fan-out
and therefore remain visible at `none`.

## v1.1 Fan-Out Experience

An eligible multi-task turn first prints a kickoff list. Once that output is
accepted, child tasks run concurrently and the attached TUI prints
`[fan-out]` lifecycle lines without enabling autonomous channel authority. The
start barrier requires every kickoff line to be written successfully; a
returned terminal error, exception, exit, or partial write leaves the kickoff
blocked and all children open for safe retry or cancellation. The
joined report lists every child and labels mixed outcomes `partial`; it is
printed before Allbert marks the exact durable report receipt delivered. If
terminal output fails, the receipt stays pending and the report can return on a
later turn.

One TUI session can track multiple active fan-outs. Each completion clears only
its own attachment, so reports can finish in either order without hiding one
another. Plain replies can steer or cancel a named child. If more than one
fan-out is active, an unqualified Escape cancellation names the ambiguity and
asks you to identify the target rather than cancelling arbitrary work.

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

## v1.2 Verify: Fresh Ready Launch And Web Continuity

Precondition this flagship row with a running real Ollama and the curated local
model pulled. Use a fresh, preserved Home and choose the transcript command for
the host OS:

```sh
export V12_TUI_HOME="$(mktemp -d /tmp/allbert-v12-tui.XXXXXX)"
export ALLBERT_HOME="$V12_TUI_HOME"
mix allbert.ecto.migrate --quiet

# macOS (BSD script)
script "$V12_TUI_HOME/v12-tui-macos.txt" mix allbert.tui

# Linux (util-linux script; use instead of the macOS line)
script -q -c 'mix allbert.tui' "$V12_TUI_HOME/v12-tui-linux.txt"
```

At the first prompt, submit one ordinary question, inspect all three settings, and
quit:

```text
What is the capital of France?
/settings get intent.direct_answer_model_enabled
/settings get channels.tui.enabled
/settings get channels.tui.identity_map
/quit
```

PASS: the first input produces a real model-backed answer, never the deterministic
fallback and never a silent drop; the local disclosure appears once. Both boolean
reads show `true`, and the identity read shows one enabled `default → local`
entry. Relaunch once with the same Home, repeat the three reads, and `/quit`; the
values must be unchanged and the disclosure must not repeat. Model-not-ready
cells have separate honest-fallback validation and do not satisfy this flagship
row.

After both sessions exit, these cross-platform checks prove that the first
launch wrote one per-key record plus one transaction record and that the restart
wrote none:

```sh
export V12_TUI_AUDIT_DIR="$ALLBERT_HOME/settings/audit"
test "$(rg -A2 '^## .* channels\.tui\.enabled$' "$V12_TUI_AUDIT_DIR"/*.md | rg -c 'actor: first-run-local-tui-bootstrap')" -eq 1
test "$(rg -A2 '^## .* channels\.tui\.identity_map$' "$V12_TUI_AUDIT_DIR"/*.md | rg -c 'actor: first-run-local-tui-bootstrap')" -eq 1
test "$(rg -A2 '^## .* settings\.transaction$' "$V12_TUI_AUDIT_DIR"/*.md | rg -c 'actor: first-run-local-tui-bootstrap')" -eq 1
echo 'PASS: one atomic local-TUI launcher bootstrap; restart added no duplicate'
```

To continue on web, first ensure the TUI has exited, then start `mix phx.server`
with this same `ALLBERT_HOME` and open `/workspace`. TUI `default` and web
`web-local` independently resolve to canonical user `local`, so eligible durable
conversation and user data can be selected on web. The TUI map does not grant
web authorization, and opening web does not automatically open the exact TUI
thread. Never run the standalone TUI and web/daemon process concurrently against
the same SQLite Home.

## v0.55.1 Warm Console Standard

v0.55.1 (`docs/plans/archives/v0.55b-request-flow.md`) hardens this same TUI into the
persistent operator/validation console. The go-forward interactive validation
standard is:

- run the deterministic `mix allbert.test release.v0551` gate first;
- prepare a fresh `ALLBERT_HOME`, migrate it with `mix allbert.ecto.migrate
  --quiet`, explicitly configure identity only when replaying the historical
  v0.55.1 contract, and preflight the Notes/files `write_note` route before launch;
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

For the exact v0.55.1 operator-validation command sequence, use
`docs/plans/archives/v0.55b-request-flow.md#operator-validation-punchlist-v0551-run-entirely-in-session`.
Inside that punchlist, confirmation state is inspected with `/confirmations` at
the live TUI prompt; do not run `mix allbert.confirmations list` between
in-session checks.

## v0.56 Intent/Model Validation Reads

v0.56 adds two read-only slash commands for release validation:

- `/intents` renders the same redacted `intent_coverage` DTO used by
  `mix allbert.intent coverage`: routable coverage, missing count, generated
  descriptors, learned-review proposals, overrides, and disabled overrides.
- `/models` renders the same redacted `model_doctor` DTO used by
  `mix allbert.settings model-doctor`: per-purpose recommended profile/model,
  configured profile/model, local-pull/egress status, and diagnostics.

Both commands require the mapped TUI identity, execute through
`Actions.Runner.run/3`, render only the action `surface_payload`, and do not
create channel-event rows or model turns. They are slash-allowlisted operator
reads only; natural-language requests to inspect intents or models must not
route into these internal actions.

## v0.57 Pi-Mode Coding Surface

v0.57 adds Pi-mode on top of this same terminal channel. It is not a replacement
for the base TUI guide: use this document for the shipped channel substrate,
identity mapping, split-payload seam, and warm-console standard; use
`docs/operator/pi-mode-coding.md` for Pi-mode operator setup, approval modes,
allowlist behavior, streaming/cancel checks, and manual validation handoff.

Legacy v0.55 manual M2 smoke:

- Start `mix allbert.tui` with the mapped identity.
- Type a normal prompt and confirm the response appears as scrollback while the
  same prompt remains live.
- Exit with `/quit`, empty `channels.tui.identity_map`, relaunch the same
  `ALLBERT_HOME`, and confirm the same terminal input is rejected without an
  assistant response.
- Restore the identity map before continuing to later M3/M5 validation.

Legacy v0.55 manual M3 approval smoke:

- Trigger an action that returns `status: :needs_confirmation`.
- Confirm the TUI prints exact typed commands plus numbered options:
  `ALLBERT:APPROVE:<id>`, `ALLBERT:DENY:<id>`, and `ALLBERT:SHOW:<id>`.
- Type one exact approval command at the same prompt.
- Confirm the resolution result is printed. For v0.55.1 validation, inspect the
  resolved confirmation with `/confirmations` inside the same TUI session; do not
  use cold `mix allbert.confirmations list` until after the session is closed.
- For a resumable target action, an `ALLBERT:APPROVE:<id>` command must resolve
  as approved and mark the target resumed; an approve command that prints
  `Confirmation <id> is denied` is a validation failure.
- Confirm no button/link affordance or target URL is printed in the terminal
  approval handoff.

Split-payload rule: runtime conversation history stores `model_payload`; terminal
renderers draw `surface_payload`. Terminal framing, ANSI styling, paging hints, or
LiveScreen prompt text must not be stored as model-facing conversation content.

v0.55 closeout note: the operator accepted the warm TUI A1-A5 validation on
2026-06-22. The separate Matrix live provider smoke is not TUI validation and is
recorded as blocked by inactive Matrix credentials until the operator refreshes
the provider token.

v0.55.1 M5 closeout note: the warm-console operator-validation punchlist passed
on 2026-06-22 in one transcript-captured `mix allbert.tui` session. The redacted
evidence and release-gate JSON were verified during release closeout; the
transcript and JSON evidence are local validation artifacts, not committed
operator docs.

## Cleanup

Stop every process that owns the Home. Preserve the Home and its audit/transcript
evidence unless it was deliberately created as disposable validation state. Do
not set `channels.tui.enabled=false` merely as cleanup: that is durable operator
intent and will block the next explicit TUI launch.
