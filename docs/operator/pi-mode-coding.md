# Pi-Mode Coding Operator Guide

Status: v0.57 M0-M9.25 are implemented, but live S4.9 validation invalidated the
M9.23-M9.25 Esc-helper capture strategy. M9.27 proves the raw input-driver
substrate with `mix allbert.tui --input-driver-proof`, and M9.28 wires that
driver into normal `mix allbert.tui`. Release closeout is blocked until
M9.29-M9.30 rewrite validation and re-gate the normal Pi-mode flow. This guide
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
- Level 1 local execution enabled only for the intended repo root and command
  set when validating or using Pi-mode `bash`.

## Configure A Validation Home

```sh
export V057_MANUAL_HOME="$(mktemp -d /tmp/allbert-v057-manual.XXXXXX)"
export ALLBERT_HOME="$V057_MANUAL_HOME"
export V057_REPO_ROOT="$(pwd)"
mix allbert.ecto.migrate --quiet

mix allbert.settings set channels.tui.identity_map '[{"external_user_id":"default","user_id":"local","enabled":true}]'
mix allbert.settings set channels.tui.enabled true
mix allbert.settings set coding.pi_mode.enabled true
mix allbert.settings set coding.trusted_operator_id local
mix allbert.settings set coding.default_approval_mode default
mix allbert.settings set coding.workspace.cwd_jail "$V057_REPO_ROOT"
mix allbert.settings set coding.model_profile pi_coding_local
mix allbert.settings set execution.local.enabled true
mix allbert.settings set execution.local.allowed_roots "[\"$V057_REPO_ROOT\"]"
mix allbert.settings set execution.local.allowed_commands '["pwd","printf"]'
mix allbert.settings set execution.local.require_confirmation true
ollama pull qwen2.5:7b
mix allbert.model doctor pi_coding_local
```

Check the important values:

```sh
mix allbert.settings get channels.tui.identity_map
mix allbert.settings get coding.pi_mode.enabled
mix allbert.settings get coding.trusted_operator_id
mix allbert.settings get coding.default_approval_mode
mix allbert.settings get coding.workspace.cwd_jail
mix allbert.settings get coding.model_profile
mix allbert.settings get execution.local.enabled
mix allbert.settings get execution.local.allowed_roots
mix allbert.settings get execution.local.allowed_commands
mix allbert.settings get execution.local.require_confirmation
```

Expected: every value matches the command above, and the cwd jail is the repo root
being validated. `execution.local.enabled` must be `true`,
`execution.local.allowed_roots` must contain the repo root,
`execution.local.allowed_commands` must contain the validation commands, and
`execution.local.require_confirmation` must be `true`. If `bash` returns
`:local_execution_disabled`, the Pi-mode approval mode has not been reached; fix
the Level 1 execution settings in the same `ALLBERT_HOME` before continuing.

## Coding Model Profile

`coding.model_profile` is the persisted profile Pi-mode uses at `/pi` session
start. The default is `pi_coding_local`; it should point to a local or private
model profile that emits real provider tool-call chunks under `ReqLLM.stream_text`
for the six Pi-mode tools. This is deliberately separate from `coding_local`,
which remains available for codegen-committee work. Use hosted coding profiles
only after explicitly accepting source-code egress for that validation home.

`/model <profile>` changes only the in-memory Pi-mode session profile. It does not
change the trusted operator, approval mode, cwd jail, permissions, or confirmation
behavior. Live assistant-token streaming and provider-level Esc cancel use the
selected profile/provider path through `ReqLLM.stream_text` and
`ReqLLM.StreamResponse.cancel`; release validation must use a profile that supports
streaming, real tool-call chunks, and provider cancel. If a model emits textual
markup such as `<function=write>` instead of a real provider tool-call event,
Pi-mode treats the turn as a profile-compatibility failure and no tool runs.
During validation, `/pi` should report `model=pi_coding_local` unless the operator
deliberately selected another known streaming/tool-call-capable profile.

## Terminal Turn Safety

The base TUI prompt input is line-oriented. Enter each natural-language
validation prompt as one physical terminal line unless a checklist step
explicitly asks for multiple commands. A hard newline submits the current line as
a complete turn.

Single-key Esc cancellation is a Pi-mode extension, not a v0.55 line-mode
feature. The M9.23-M9.25 side-channel/helper approaches did not pass live S4.9:
literal `^[` scrollback, `Esc cancellation monitor unavailable: ...`, or
`/dev/tty: Device not configured` mean the terminal-input substrate is still
blocked. M9.27's proof harness and M9.28's normal-launch smoke show the
replacement substrate can consume Esc without `^[`; do not treat `^[` as an
operator typo. It remains release-blocking TUI input evidence if it appears after
M9.28, and S4.9 must be rewritten before validation resumes.

`/quit` and `/exit` are local TUI lifecycle aliases. They must stop the terminal
session and must never be routed to the model, even if prior Esc/control bytes were
echoed into the terminal line buffer.

During an async Pi-mode coding turn, progress is written as ordinary transcript
scrollback, not an erased terminal-live block. It may show assistant byte counts,
tool names, tool-result counts, cancellation status, and `Turn complete`. It must
not show raw JSON, full tool arguments, large tool-result bodies, or shell/file
output while the turn is still running, and it must be coalesced rather than
printed once per provider token. The final rendered response is the canonical
transcript output and should appear before the next `allbert:default>` prompt. A
final answer that paints over a prompt, a prompt that opens while the previous
coding turn is still streaming, raw transient JSON, blank repaint gaps, or
per-token progress spam are TUI rendering failures and not acceptable release
evidence.

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

In the TUI transcript, a streamed coding turn that needs confirmation must still
print the exact approval command, for example `ALLBERT:APPROVE:<id>`. Streamed
assistant text without the approval command is not valid confirmation evidence.
Typing the exact approval command for a pending coding `write`, `edit`, or `bash`
must resume the original Pi-mode action with its original cwd jail/session
context, then resolve the confirmation as approved. `ALLBERT:APPROVE:<id>` printing
`Confirmation <id> is denied` is a validation failure, not an acceptable denial.

The "always allow this command" affordance stores a remembered command grant under
Allbert Home, scoped by repo fingerprint, permission, cwd, canonical command, and
optional expiry. It is listable, revocable, auditable, and never a permission
grant.

In TUI validation, typed confirmation commands approve, deny, or show a pending
confirmation. Remembering a command grant uses the confirmation CLI in a second
terminal with the same `ALLBERT_HOME`: `mix allbert.confirmations approve
<confirmation-id> --remember exact`. Inspect and revoke the stored grant with
`mix allbert.resources grants list|show|revoke`. A successful remembered `bash`
approval prints `status=approved`, `Target: bash status=completed`, and
`Remembered grant: ... run_shell_command execute canonical_command:...`. If the
target command completed but the CLI ends with `:resource_ref_not_found`, the
running code is older than M9.22 or the command-grant handoff regressed; create a
fresh pending command confirmation after updating before retrying the remember
step.

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

`bash` is host execution at ADR 0009 Level 1. Prefer the argv shape
(`executable` plus `args`) for ordinary commands. If a model or operator supplies
a plain `command` string such as `pwd` or `printf 'hello\n'`, Pi-mode normalizes it
to argv when no shell syntax is present. Raw shell syntax remains stronger:
pipes, redirection, `&&`, `;`, backgrounding, command substitution, backticks, and
newline command separators are raw-shell requests and are available only at the
local-coding operator tier when `coding.bash.allow_raw_shell=true`. Non-tier
callers are argv-only or refused.

Before any Pi-mode approval prompt can appear, `bash` must also pass the
Settings-backed Level 1 execution policy: `execution.local.enabled=true`, cwd
inside the allowed root/coding jail, executable present in
`execution.local.allowed_commands`, env keys allowed, and requested limits within
policy. A disabled Level 1 policy is a preflight/setup failure, not an
`accept-edits` behavior. A real `bash` tool call for a simple allowed command that
ends in a prose workaround instead of a pending confirmation means the running TUI
process is stale or the bash boundary regressed.

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

## Cancellation

Esc cancellation has two layers. During provider streaming, Pi-mode invokes the
registered `ReqLLM.StreamResponse.cancel` callback and then shuts down the supervised
turn task through `Coding.TurnSupervisor`. During an already-running tool action,
the turn still shuts down and writes partial-turn evidence, but the tool effect is
bounded by the registered action and command timeout/brutal-kill policy; v0.57 does
not add a separate child-process cancel hook beyond that action boundary.

There is also a terminal-input layer. Provider cancel can be correctly wired while
the operator Esc key still fails to reach it. Release evidence must therefore show
both: the input driver consumes a standalone Esc without literal `^[`, and the
runtime invokes the registered provider cancel callback.

For release validation, use a coding profile that streams tokens, emits tool calls,
and exposes provider cancel. If the selected profile cannot do those three things,
the provider/model choice is not valid for v0.57 release closeout.

## Evidence

For release closeout, keep:

- the `release.v057 evidence:` path printed by the deterministic gate;
- `$V057_MANUAL_HOME`;
- the TUI transcript path;
- whether provider streaming/provider cancel were validated with the selected
  `coding.model_profile`;
- whether model-driven `read`/`grep`/`write` or `edit`/`bash` calls executed
  through the agent loop with expected confirmation behavior;
- the remembered command grant id from validation, plus list/show/revoke results
  and post-revoke prompt behavior;
- any failed command and its exact output.

The allowlist store must live under Allbert Home, not the repo. Transcripts and
trace summaries must redact secrets.
