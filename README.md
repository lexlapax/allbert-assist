# Allbert Assist

Allbert Assist is a Phoenix umbrella app for a local, Jido-centered personal
assistant runtime. v0.01 proves the first usable loop: submit a prompt from CLI,
IEx, or LiveView; route it through Jido signals and a primary intent agent; run
validated actions; persist markdown memory; and write inspectable traces when
enabled.

## v0.01 Capabilities

- Signal-first runtime boundary: `AllbertAssist.Runtime.submit_user_input/1`
- Primary intent agent: `AllbertAssist.Agents.IntentAgent`
- Explicit Jido actions for direct answers, memory, skill inspection, command
  planning, and external-network recognition
- Permission gate for read-only work, memory writes, command planning, command
  execution denial, and external-network confirmation
- Markdown memory under `ALLBERT_MEMORY_ROOT` or `var/allbert/memory`
- Low-risk personal preference heuristics, such as "my name is Sandeep" and
  "I prefer short updates"
- Markdown traces under the memory `traces` category when tracing is enabled
- CLI entrypoint with `mix allbert.ask`
- Phoenix LiveView at `http://localhost:4000/agent`

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
export ALLBERT_MEMORY_ROOT=/tmp/allbert-v001-demo
export ALLBERT_TRACE_ENABLED=true
rm -rf "$ALLBERT_MEMORY_ROOT"
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

Inspect generated files:

```sh
find "$ALLBERT_MEMORY_ROOT" -maxdepth 2 -type f | sort
```

## Browser Demo

Start Phoenix:

```sh
export ALLBERT_MEMORY_ROOT=/tmp/allbert-v001-demo
export ALLBERT_TRACE_ENABLED=true
mix phx.server
```

Open:

```text
http://localhost:4000/agent
```

The LiveView uses the same runtime boundary as the CLI and displays response
status, signal id, and trace path when tracing is enabled.

## Runtime Configuration

- `ALLBERT_MEMORY_ROOT`: root for markdown memory and traces
- `ALLBERT_TRACE_ENABLED=true`: enable trace recording
- `OLLAMA_BASE_URL`: OpenAI-compatible Ollama base URL

## Project Docs

- Development guide: `DEVELOPMENT.md`
- Vision: `docs/plans/allbert-jido-vision.md`
- Roadmap: `docs/plans/roadmap.md`
- v0.01 plan: `docs/plans/v0.01-plan.md`
- v0.01 request flow: `docs/plans/v0.01-request-flow.md`
- ADRs: `docs/adr/`

## Safety Boundaries

v0.01 is local and conservative:

- It does not execute shell commands.
- It does not make external network calls.
- Sensitive-looking personal data is not silently stored unless explicit memory
  intent is present.
- Side effects go through named actions with permission decisions and optional
  trace records.
