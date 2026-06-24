# Pi-Mode Coding Operator Guide

Status: v0.57 M0-M9.8 are implemented. Release closeout is blocked on warm
operator validation against a real streaming/tool-capable coding profile. This guide
describes the operator workflow for the Pi-mode coding surface. The
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
mix allbert.settings set coding.model_profile coding_local
```

Check the important values:

```sh
mix allbert.settings get channels.tui.identity_map
mix allbert.settings get coding.pi_mode.enabled
mix allbert.settings get coding.trusted_operator_id
mix allbert.settings get coding.default_approval_mode
mix allbert.settings get coding.workspace.cwd_jail
mix allbert.settings get coding.model_profile
```

Expected: every value matches the command above, and the cwd jail is the repo root
being validated.

## Coding Model Profile

`coding.model_profile` is the persisted profile Pi-mode uses at `/pi` session
start. The default is `coding_local`; it should point to a local or private
code-capable model profile with enough context for repo work. Use hosted coding
profiles only after explicitly accepting source-code egress for that validation
home.

`/model <profile>` changes only the in-memory Pi-mode session profile. It does not
change the trusted operator, approval mode, cwd jail, permissions, or confirmation
behavior. Live assistant-token streaming and provider-level Esc cancel use the
selected profile/provider path through `ReqLLM.stream_text` and
`ReqLLM.StreamResponse.cancel`; release validation must use a profile that supports
streaming, tool calling, and provider cancel.

## Approval Modes

`default` prompts before file writes, edits, and shell execution.

`accept-edits` reduces confirmation friction for `write` and `edit`, but it does
not auto-approve `bash`.

`plan` executes only read/search tools (`read`, `grep`, `glob`). It does not
execute `write`, `edit`, or `bash`.

`tier` is the cheapest mode and is available only when the local-coding operator
tier resolves: trusted operator, main session, `tui`, not channel-originated,
not scheduled, and not generated-code.

Confirmation timing is mode-dependent. In `default` mode, a model-proposed
`write`, `edit`, or `bash` returns a pending confirmation and the file/command
effect has not happened. The model loop may finish after receiving that bounded
pending result; approving the confirmation resumes the registered action later
through the normal confirmation path, not inside the same LLM stream. In
`accept-edits` or `tier` mode, an effect can complete during the same loop only
when Security Central suppresses the prompt while preserving the original
`:needs_confirmation` decision, trace, and audit.

The "always allow this command" affordance stores a remembered command grant under
Allbert Home, scoped by repo fingerprint, permission, cwd, canonical command, and
optional expiry. It is listable, revocable, auditable, and never a permission
grant.

## Tool Boundaries

`read`, `grep`, and `glob` are read-only but sensitive. They run without a
confirmation prompt, but still pass Runner/Security Central and enforce cwd jail,
ignore policy, output caps, redaction, trace, and audit.

All six coding actions are internal registered capabilities. They are not
intent-agent tools, public protocol tools, or channel-routable actions outside an
active Pi-mode session; a direct out-of-session call is denied before filesystem or
shell work starts.

Inside an active Pi-mode coding turn, the six actions are bound as session-local
`ReqLLM.Tool` definitions. Model-proposed tool calls are advisory; Allbert executes
them only through `Actions.Runner.run/3`, appends bounded tool results back into the
session `ReqLLM.Context`, and continues streaming until the model stops calling
tools. The TUI-held session context is updated after the turn; `/clear` resets it.

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
| `/pi [path]` | Enter Pi-mode and pin the realpath-resolved cwd jail for the session; `/pi off` exits. |
| `/mode [default\|accept-edits\|plan\|tier]` | Ungated in-memory approval-mode switch; no `:coding_session_write` atom. |
| `/diff <path>` | Read-only coding diff/context view through the coding file-read boundary. |
| `/model <profile>` | Ungated in-memory session model change; no `:coding_session_write` atom. |
| `/clear` | Ungated session context reset; no `:coding_session_write` atom. |
| `/compact` | Ungated context compaction; no `:coding_session_write` atom. |
| `/init [path]` | Scaffolds a Pi-mode context file through the coding file-write boundary; default path is `.allbert/pi-mode.md`. |

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
- whether provider streaming/provider cancel were validated with the selected
  `coding.model_profile`;
- whether model-driven `read`/`grep`/`write` or `edit`/`bash` calls executed
  through the agent loop with expected confirmation behavior;
- any failed command and its exact output.

The allowlist store must live under Allbert Home, not the repo. Transcripts and
trace summaries must redact secrets.
