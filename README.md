# Allbert Assist

Allbert Assist is a Phoenix umbrella app for a local, Jido-centered personal
assistant runtime. v0.05 adds Security Central on top of the local control
plane: submit a prompt from CLI or LiveView; route it through Jido signals, the
intent agent, registered actions, and the shared action runner; persist
markdown memory; write inspectable traces; manage typed settings, provider
profiles, and encrypted local secrets through Settings Central; discover, read,
and activate standard `SKILL.md` skill folders; and evaluate permission, risk,
trust, redaction, audit, and trace metadata without granting new execution
authority.

## Current Capabilities

- Signal-first runtime boundary: `AllbertAssist.Runtime.submit_user_input/1`
- Primary intent agent: `AllbertAssist.Agents.IntentAgent`
- Registered action boundary: `AllbertAssist.Actions.Registry` and
  `AllbertAssist.Actions.Runner.run/3`
- Explicit Jido actions for direct answers, memory, skill inspection, command
  planning, and external-network recognition
- Security Central for read-only work, memory writes, command planning,
  command execution denial, external-network confirmation, settings writes,
  settings secret boundaries, risk, redaction, audit, trace, and trust
  metadata
- Allbert Home path foundation under `ALLBERT_HOME`, alias
  `ALLBERT_HOME_DIR`, defaulting to `~/.allbert`
- Settings Central under `<ALLBERT_HOME>/settings`, with typed YAML settings,
  permission defaults, encrypted `secrets.yml.enc`, and append-only audit
  markdown
- Provider and model profiles with redacted credential status
- Agent Skills-compatible parser, registry, trust policy, built-in skill pack,
  and progressive-disclosure `activate_skill` action
- Markdown memory under `<ALLBERT_HOME>/memory`, with `ALLBERT_MEMORY_ROOT` as
  a specific override
- Low-risk personal preference heuristics, such as "my name is Sandeep" and
  "I prefer short updates"
- Markdown traces under the memory `traces` category when tracing is enabled
- CLI entrypoint with `mix allbert.ask`
- Settings and security CLIs with `mix allbert.settings` and `mix
  allbert.security status`
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
export ALLBERT_HOME=/tmp/allbert-v005-demo
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

Inspect generated files:

```sh
find "$ALLBERT_HOME/memory" -maxdepth 2 -type f | sort
```

## Browser Demo

Start Phoenix:

```sh
export ALLBERT_HOME=/tmp/allbert-v005-demo
export ALLBERT_TRACE_ENABLED=true
mix phx.server
```

Open:

```text
http://localhost:4000/agent
http://localhost:4000/settings
```

The LiveViews use the same runtime, settings, and security boundaries as the
CLI. `/settings` includes Security & Permissions controls backed by Settings
Central actions and read-only effective Security Central status.

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
- ADRs: `docs/adr/`

## Safety Boundaries

Allbert remains local and conservative:

- It does not execute shell commands.
- It does not make external network calls.
- It does not execute bundled skill scripts, package installs, or code from
  skill folders.
- Sensitive-looking personal data is not silently stored unless explicit memory
  intent is present.
- Raw provider credentials are never displayed and are stored only in the
  encrypted Settings Central secret store.
- Side effects go through named actions with permission decisions and optional
  trace records.
