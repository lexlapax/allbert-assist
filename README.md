# Allbert

Allbert is a terminal-first personal assistant with a small Rust kernel, markdown bootstrap files, markdown memory, skills, built-in tools, security checks, cost tracking, and trace logging.

v0.1 targets a technical local CLI user. You build it from source, point it at an Anthropic or OpenRouter API key, complete a guided first-run setup flow, and then use the REPL.

## What v0.1 includes

- a Rust kernel that owns the agent loop, tools, memory, skills, policy, cost, and tracing
- a REPL frontend
- bootstrap personality files under `~/.allbert/`
- built-in tools for process exec, filesystem access, input, web fetch/search, skills, and memory
- explicit workspace trust through `fs_roots`
- slash commands for `/help`, `/cost`, `/model`, `/setup`, `/status`, and `/exit`

## Prerequisites

- Rust toolchain with `cargo`
- a provider API key:
  - `ANTHROPIC_API_KEY` for Anthropic
  - `OPENROUTER_API_KEY` for OpenRouter

Export at least one before your first live turn:

```bash
export ANTHROPIC_API_KEY=...
```

or

```bash
export OPENROUTER_API_KEY=...
```

## Build and run

Start the REPL:

```bash
cargo run -p allbert-cli --
```

Enable debug trace logging:

```bash
cargo run -p allbert-cli -- --trace
```

Auto-confirm risky actions for the current session only:

```bash
cargo run -p allbert-cli -- --yes
```

## First run

On first run, Allbert creates `~/.allbert/`, seeds bootstrap files, writes `config.toml`, and starts a guided setup flow before the REPL opens.

The setup wizard asks for:

- your preferred name (the name Allbert should call you)
- your timezone, with a guessed default when available
- how Allbert should usually work with you, with a practical default
- your current priorities, with a safe fallback if you have none to record yet
- optional assistant identity refinements for Allbert itself
- trusted filesystem roots, with the current project directory offered as the default first root

Trusted roots matter: file tools are disabled outside the directories you explicitly trust. The wizard recommends the current working directory but does not auto-trust it.

When setup completes successfully:

- `config.toml` gets `setup.version = 1`
- bootstrap files are updated with your confirmed values
- `BOOTSTRAP.md` is removed

If you cancel setup, Allbert exits without entering the REPL and leaves setup incomplete.

## Everyday use

Useful slash commands:

- `/help` shows command help
- `/status` shows provider, setup state, trusted roots, API-key presence, installed skill count, and trace mode
- `/setup` reruns guided setup
- `/model` shows the active provider and model
- `/model <anthropic|openrouter> <model_id> [api_key_env]` switches model/provider at runtime
- `/cost` shows session cost and today's recorded total
- `/exit` leaves the REPL

Example:

```text
/model openrouter <model_id> OPENROUTER_API_KEY
```

## Skills and memory

Allbert stores skills under `~/.allbert/skills/`. The repo ships an example skill at `examples/skills/note-taker/SKILL.md`.

To install that example locally:

```bash
mkdir -p ~/.allbert/skills
cp -r examples/skills/note-taker ~/.allbert/skills/
```

Memory lives under `~/.allbert/memory/`:

- `MEMORY.md` is the always-nearby index
- `daily/` holds dated notes
- `topics/`, `people/`, `projects/`, and `decisions/` are durable buckets for deeper notes

Chat history is not the durable store. Important facts need to be written into memory files.

## Files you should know

- `~/.allbert/config.toml`
- `~/.allbert/SOUL.md`
- `~/.allbert/USER.md`
- `~/.allbert/IDENTITY.md`
- `~/.allbert/TOOLS.md`
- `~/.allbert/skills/`
- `~/.allbert/memory/`
- `~/.allbert/costs.jsonl`
- `~/.allbert/traces/`

## Current limitations

- terminal-only in v0.1
- source-based install only
- no runtime `/trace` toggle; use `--trace` at startup
- no streaming responses
- no persisted chat transcript memory
- live provider use depends on your network and API-key env vars

## More detail

See [docs/onboarding-and-operations.md](docs/onboarding-and-operations.md) for the detailed setup flow, config examples, trusted-root guidance, and troubleshooting.
