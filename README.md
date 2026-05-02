# Allbert Assist

Allbert Assist is a Phoenix umbrella app for a local, Jido-centered personal
assistant runtime. v0.08 is ready for user testing as the local execution
sandbox and shell adapter release: submit a prompt from CLI or LiveView; route
it through Jido signals, the intent agent, validated skill contracts,
registered actions, Security Central, and the shared action runner; pause
confirmation-required work as durable Allbert Home records; approve or deny
from CLI or `/settings`; execute confirmed Level 1 local shell commands through
`run_shell_command`; persist markdown memory; write inspectable traces and
execution audit records; manage typed settings, provider profiles, and
encrypted local secrets through Settings Central; discover, read, activate,
validate, and scaffold standard `SKILL.md` skill folders without granting
unplanned execution authority.

## Current Capabilities

- Signal-first runtime boundary: `AllbertAssist.Runtime.submit_user_input/1`
- Primary intent agent: `AllbertAssist.Agents.IntentAgent`
- Registered action boundary: `AllbertAssist.Actions.Registry` and
  `AllbertAssist.Actions.Runner.run/3`
- Explicit Jido actions for direct answers, memory, skill inspection, command
  planning, confirmed local shell execution, and external-network recognition
- Action-backed built-in skills for direct answers, markdown memory,
  skill list/read, command planning, and external-network recognition
- Security Central for read-only work, memory writes, command planning,
  confirmed command execution, external-network confirmation, settings writes,
  skill scaffold writes, settings secret boundaries, risk, redaction, audit,
  trace, and trust metadata
- Allbert Home path foundation under `ALLBERT_HOME`, alias
  `ALLBERT_HOME_DIR`, defaulting to `~/.allbert`
- Settings Central under `<ALLBERT_HOME>/settings`, with typed YAML settings,
  permission defaults, encrypted `secrets.yml.enc`, and append-only audit
  markdown
- Provider and model profiles with redacted credential status
- Durable confirmation queue under `<ALLBERT_HOME>/confirmations`, with
  pending/resolved YAML records and markdown audit entries
- Level 1 local shell execution audit under `<ALLBERT_HOME>/execution/audit`
- Registered confirmation actions and CLI: `mix allbert.confirmations list`,
  `show`, `approve`, `deny`, and `expire`
- Deterministic shell request CLI: `mix allbert.exec --cwd "$WORKSPACE" -- ls -la`
- Confirmation Requests section in `/settings` over the same action boundary
  as the CLI
- Agent Skills-compatible parser, registry, trust policy, built-in skill pack,
  action-backed contract validation, local validation/scaffold helpers, and
  progressive-disclosure `activate_skill` action
- Markdown memory under `<ALLBERT_HOME>/memory`, with `ALLBERT_MEMORY_ROOT` as
  a specific override
- Low-risk personal preference heuristics, such as "my name is Sandeep" and
  "I prefer short updates"
- Markdown traces under the memory `traces` category when tracing is enabled
- CLI entrypoint with `mix allbert.ask`
- Settings, security, and skill helper CLIs with `mix allbert.settings`, `mix
  allbert.security status`, and `mix allbert.skills`
- Phoenix LiveViews at `http://localhost:4000/agent` and
  `http://localhost:4000/settings`

## Requirements

- Elixir/Erlang matching the project toolchain
- SQLite
- Optional local Ollama server for future LLM-backed use of the `:local` model
  alias. The deterministic v0.01 runtime path does not require a live model.

The `:local` model alias is configured as `gemma4:26b` through the
OpenAI-compatible Ollama endpoint. Override the endpoint with:

```sh
export OLLAMA_BASE_URL=http://localhost:11434/v1
```

## Setup

For development conventions and agent onboarding, read `DEVELOPMENT.md`.

```sh
mix setup
```

Run the full project gate:

```sh
mix precommit
```

Run static checks including Dialyzer:

```sh
MIX_ENV=test mix check
```

Dialyzer has a narrow `.dialyzer_ignore.exs` for known `Jido.AI.Agent`
macro-generated warnings. `list_unused_filters: true` is enabled so stale
ignores are reported.

## CLI Demo

Use a disposable memory root:

```sh
export ALLBERT_HOME=/tmp/allbert-v007-demo
export ALLBERT_TRACE_ENABLED=true
rm -rf "$ALLBERT_HOME"
```

Ask Allbert to remember something:

```sh
mix allbert.ask --trace "remember that I like concise milestone handoffs"
```

Recall it:

```sh
mix allbert.ask --trace "what do you remember about milestone handoffs?"
```

Confirm command execution is blocked:

```sh
mix allbert.ask --trace "run a destructive shell command"
```

Inspect and activate registry-backed skills:

```sh
mix allbert.ask --trace "what skills are available?"
mix allbert.ask --trace "read skill append-memory"
mix allbert.ask --trace "activate skill append-memory"
```

Validate and scaffold local skill wrappers:

```sh
mix allbert.skills validate apps/allbert_assist/priv/skills/append-memory
mix allbert.skills create demo-memory append_memory memory_write "Save a short memory helper" --root "$ALLBERT_HOME/skills"
```

Inspect and update Settings Central:

```sh
mix allbert.settings list
mix allbert.settings set operator.communication_style concise
mix allbert.settings explain operator.communication_style
printf 'test-key\n' | mix allbert.settings providers set-key openai
mix allbert.settings providers list
```

Inspect Security Central and safety floors:

```sh
mix allbert.security status
mix allbert.settings set permissions.command_execute allowed
mix allbert.security status
```

Prepare a disposable v0.08 local shell workspace:

```sh
WORKSPACE="$(mktemp -d /tmp/allbert-v08-shell.XXXXXX)"
printf 'fixture\n' > "$WORKSPACE/README.md"
mix allbert.settings set permissions.command_execute allowed
mix allbert.settings set execution.local.enabled true
mix allbert.settings set execution.local.allowed_roots "$WORKSPACE"
mix allbert.exec --cwd "$WORKSPACE" -- ls -la
mix allbert.confirmations list
mix allbert.confirmations approve <confirmation-id> --reason "operator shell smoke"
mix allbert.confirmations list --resolved
```

The same action boundary is used from prompt routing:

```sh
mix allbert.ask "run pwd"
```

Create and inspect an external-network confirmation request:

```sh
mix allbert.ask --trace "fetch https://example.com from the internet"
mix allbert.confirmations list
mix allbert.confirmations show <confirmation-id>
mix allbert.confirmations approve <confirmation-id> --reason "operator smoke"
mix allbert.confirmations list --resolved
```

In v0.07 that approval resolves as `adapter_unavailable`; it records the
operator decision and still makes no network call. The CLI and `/settings`
explain this as approved, recorded, and not executed because v0.07 has no
adapter for that target; external network execution is planned for v0.10.

Release/tag status: v0.08 is ready for user testing as of 2026-05-02. Release
tag is pending operator acceptance. Expected tag name: `v0.08`; no v0.08 tag
has been created or pushed yet.

Inspect generated files:

```sh
find "$ALLBERT_HOME/memory" -maxdepth 2 -type f | sort
```

## Browser Demo

Start Phoenix:

```sh
export ALLBERT_HOME=/tmp/allbert-v007-demo
export ALLBERT_TRACE_ENABLED=true
mix phx.server
```

Open:

```text
http://localhost:4000/agent
http://localhost:4000/settings
```

The LiveViews use the same runtime, settings, security, and confirmation
boundaries as the CLI. `/settings` includes Security & Permissions controls
and Confirmation Requests backed by registered actions and read-only effective
Security Central status.

## Runtime Configuration

- `ALLBERT_HOME`: root for Allbert runtime data; defaults to `~/.allbert`
- `ALLBERT_HOME_DIR`: compatibility alias for `ALLBERT_HOME`
- `ALLBERT_SETTINGS_ROOT`: specific override for Settings Central
- `ALLBERT_SETTINGS_MASTER_KEY`: base64-encoded 32-byte secret-store key
- `ALLBERT_MEMORY_ROOT`: root for markdown memory and traces
- `ALLBERT_TRACE_ENABLED=true`: enable trace recording
- `OLLAMA_BASE_URL`: OpenAI-compatible Ollama base URL

## Project Docs

- Development guide: `DEVELOPMENT.md`
- Vision: `docs/plans/allbert-jido-vision.md`
- Roadmap: `docs/plans/roadmap.md`
- v0.01 plan: `docs/plans/v0.01-plan.md`
- v0.01 request flow: `docs/plans/v0.01-request-flow.md`
- v0.02 plan: `docs/plans/v0.02-plan.md`
- v0.02 request flow: `docs/plans/v0.02-request-flow.md`
- v0.03 plan: `docs/plans/v0.03-plan.md`
- v0.03 request flow: `docs/plans/v0.03-request-flow.md`
- v0.04 plan: `docs/plans/v0.04-plan.md`
- v0.04 request flow: `docs/plans/v0.04-request-flow.md`
- v0.05 plan: `docs/plans/v0.05-plan.md`
- v0.05 request flow: `docs/plans/v0.05-request-flow.md`
- v0.06 plan: `docs/plans/v0.06-plan.md`
- v0.06 request flow: `docs/plans/v0.06-request-flow.md`
- v0.07 plan: `docs/plans/v0.07-plan.md`
- v0.07 request flow: `docs/plans/v0.07-request-flow.md`
- v0.08 plan: `docs/plans/v0.08-plan.md`
- v0.08 request flow: `docs/plans/v0.08-request-flow.md`
- ADRs: `docs/adr/`

## Safety Boundaries

Allbert remains local and conservative:

- v0.08 executes confirmed local shell commands only through registered Jido
  action `run_shell_command` and Level 1 local policy sandboxing, with
  conservative default read-only commands and explicit operator profiles for
  additional local developer commands.
- It does not make external network calls.
- It records external-network approval as `adapter_unavailable` until a future
  registered `Req` adapter is implemented and confirmed; this is intentional
  adapter scaffolding, not an execution error.
- It does not execute bundled skill scripts, package installs, or code from
  skill folders.
- It does not claim Docker, Podman, Mac/Linux container, remote, or microVM
  isolation yet; that future work is parked in `docs/plans/future-features.md`.
- Sensitive-looking personal data is not silently stored unless explicit memory
  intent is present.
- Raw provider credentials are never displayed and are stored only in the
  encrypted Settings Central secret store.
- Side effects go through named actions with permission decisions and optional
  trace records.
