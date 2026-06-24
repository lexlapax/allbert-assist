# Pi-Mode Coding Operator Guide

Status: planned for v0.57; M0-M5 are implemented. This guide describes the target
operator workflow for the Pi-mode coding surface after implementation. The
release-authoritative validation checklist lives in
`docs/plans/v0.57-request-flow.md#operator-validation`.

Pi-mode runs inside the persistent `tui` channel. It is not a separate runtime and
does not grant authority by being local. Every coding tool routes through
`Actions.Runner.run/3`, Security Central, trace, and audit.

## Requirements

- v0.55 `tui` channel and v0.55.1 warm operator console are present.
- A disposable `ALLBERT_HOME` for validation and release smokes.
- A mapped TUI identity for the terminal profile.
- `coding.pi_mode.enabled=true`.
- `coding.trusted_operator_id` set to the mapped local operator only for the
  validation home or the operator's intended Pi-mode home.

## Configure A Validation Home

```sh
export V057_MANUAL_HOME="$(mktemp -d /tmp/allbert-v057-manual.XXXXXX)"
export ALLBERT_HOME="$V057_MANUAL_HOME"
mix allbert.ecto.migrate --quiet

mix allbert.settings set channels.tui.identity_map '[{"external_user_id":"default","user_id":"local","enabled":true}]'
mix allbert.settings set channels.tui.enabled true
mix allbert.settings set coding.pi_mode.enabled true
mix allbert.settings set coding.trusted_operator_id local
mix allbert.settings set coding.default_approval_mode default
mix allbert.settings set coding.workspace.cwd_jail "$(pwd)"
```

Check the important values:

```sh
mix allbert.settings get channels.tui.identity_map
mix allbert.settings get coding.pi_mode.enabled
mix allbert.settings get coding.trusted_operator_id
mix allbert.settings get coding.default_approval_mode
mix allbert.settings get coding.workspace.cwd_jail
```

Expected: every value matches the command above, and the cwd jail is the repo root
being validated.

## Approval Modes

`default` prompts before file writes, edits, and shell execution.

`accept-edits` reduces confirmation friction for `write` and `edit`, but it does
not auto-approve `bash`.

`plan` executes only read/search tools (`read`, `grep`, `glob`). It does not
execute `write`, `edit`, or `bash`.

`tier` is the cheapest mode and is available only when the local-coding operator
tier resolves: trusted operator, main session, `tui`, not channel-originated,
not scheduled, and not generated-code.

The "always allow this command" affordance stores a remembered command grant under
Allbert Home, scoped by repo fingerprint, permission, cwd, canonical command, and
optional expiry. It is listable, revocable, auditable, and never a permission
grant.

## Tool Boundaries

`read`, `grep`, and `glob` are read-only but sensitive. They run without a
confirmation prompt, but still pass Runner/Security Central and enforce cwd jail,
ignore policy, output caps, redaction, trace, and audit.

`write` and `edit` use the coding file-write permission. `edit` is exact-match and
must fail clearly when the match is missing.

`bash` is host execution at ADR 0009 Level 1. Raw shell strings are available only
at the local-coding operator tier. Non-tier callers are argv-only or refused.

## Slash Commands

The coding slash set is slash-allowlisted and non-routable. These commands are not
intent candidates and do not create model turns:

| Command | Effect |
|---|---|
| `/help` | Router-local read. |
| `/diff` | Read-only coding diff view through the coding file-read boundary. |
| `/model <profile>` | Ungated in-memory session model change; no `:coding_session_write` atom. |
| `/clear` | Ungated session context reset; no `:coding_session_write` atom. |
| `/compact` | Ungated context compaction; no `:coding_session_write` atom. |
| `/init` | Scaffolds `AGENTS.md` through the coding file-write boundary. |

`@file` mentions use the same bounded `read` action as ordinary read requests.
They never ingest raw paths outside the cwd jail.

## Run

Run the deterministic release gate first:

```sh
ALLBERT_TEST_KEEP_TMP=1 MIX_ENV=test mix allbert.test release.v057
```

Then launch one persistent transcript-captured TUI session:

```sh
script "$V057_MANUAL_HOME/v057-pi-mode-transcript.txt" mix allbert.tui
```

Keep this session open for the entire manual punchlist. Do not fall back to cold
`mix allbert.ask` turns during validation.

## Evidence

For release closeout, keep:

- the `release.v057 evidence:` path printed by the deterministic gate;
- `$V057_MANUAL_HOME`;
- the TUI transcript path;
- whether cancellation used direct provider abort or degraded to timeout;
- any failed command and its exact output.

The allowlist store must live under Allbert Home, not the repo. Transcripts and
trace summaries must redact secrets.
