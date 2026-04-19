# Allbert

Allbert is a terminal-first personal assistant built around a small Rust kernel, markdown bootstrap files, markdown memory, skills, built-in tools, policy checks, cost tracking, and a local daemon runtime.

v0.2 targets a technical source-based user. You build it from source, point it at an Anthropic or OpenRouter API key, complete a guided first-run setup flow, and then use `allbert-cli` as the primary entry point for REPL work, daemon lifecycle commands, and recurring jobs.

The daemon-backed jobs substrate, prompt-facing job tools, and explicit preview-and-confirm flow for durable schedule mutation are implemented today. The remaining v0.2 closeout work is final conversational polish: help text, docs, and end-to-end smoke that make scheduling through normal conversation feel as trustworthy as the operator CLI.

## What v0.2 includes

- a kernel that owns the agent loop, tools, memory, skills, policy, cost, and tracing
- a local daemon host with attachable REPL, CLI, and jobs channels
- daemon-backed REPL sessions with reconnectable in-memory session state while the daemon is alive
- markdown bootstrap personality files under `~/.allbert/`
- built-in tools for process exec, filesystem access, input, web fetch/search, skills, and memory
- explicit workspace trust through `fs_roots`
- daemon lifecycle commands under `allbert-cli daemon ...`
- recurring jobs under `allbert-cli jobs ...` and the `allbert-jobs` alias
- bundled disabled maintenance job templates

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

Start the primary REPL:

```bash
cargo run -p allbert-cli --
```

Check daemon status:

```bash
cargo run -p allbert-cli -- daemon status
```

List jobs:

```bash
cargo run -p allbert-cli -- jobs list
```

The dedicated alias still works if you prefer it:

```bash
cargo run -p allbert-jobs -- list
```

Enable daemon debug logging for the running daemon:

```bash
cargo run -p allbert-cli -- --trace
```

This turns on debug output in `~/.allbert/logs/daemon.debug.log`.

Auto-confirm risky actions for the current REPL session only:

```bash
cargo run -p allbert-cli -- --yes
```

## First run

On first run, Allbert creates `~/.allbert/`, seeds bootstrap files, seeds bundled job templates, writes `config.toml`, and starts a guided setup flow before the daemon-backed REPL opens.

The setup wizard asks for:

- your preferred name, meaning the name Allbert should call you
- your timezone, with a guessed default when available
- how Allbert should usually work with you, with a practical default
- your current priorities, with a safe fallback if you have none to record yet
- optional assistant identity refinements for Allbert itself
- trusted filesystem roots, with the current project directory offered as the default first root
- whether the CLI should auto-start the daemon when needed
- whether recurring jobs are enabled in this profile
- the default timezone for scheduled jobs
- whether to enable any bundled maintenance job templates immediately

Trusted roots matter: file tools are disabled outside the directories you explicitly trust. The wizard recommends the current working directory but does not auto-trust it.

When setup completes successfully:

- `config.toml` gets `setup.version = 2`
- bootstrap files are updated with your confirmed values
- daemon/jobs defaults are written into config
- selected bundled job templates are copied into `~/.allbert/jobs/definitions/`
- `BOOTSTRAP.md` is removed

If you cancel setup, Allbert exits without entering the REPL and leaves setup incomplete.

## Everyday use

REPL slash commands:

- `/h` is an alias for `/help`
- `/help` shows command help
- `/s` is an alias for `/status`
- `/status` shows provider, setup state, trusted roots, daemon/jobs defaults, API-key presence, installed skill count, and trace mode
- `/setup` reruns guided setup and reloads config for the current daemon session
- `/model` shows the active session model
- `/model <anthropic|openrouter> <model_id> [api_key_env]` switches model/provider for the attached session only
- `/cost` shows session cost and today's recorded total
- `/exit` leaves the REPL without stopping the daemon

Unknown slash commands are rejected locally instead of being sent through to the model.

Daemon commands:

- `allbert-cli daemon status`
- `allbert-cli daemon start`
- `allbert-cli daemon stop`
- `allbert-cli daemon restart`
- `allbert-cli daemon logs [--debug] [--follow] [--lines N]`

Jobs commands:

- `allbert-cli jobs list`
- `allbert-cli jobs status <name>`
- `allbert-cli jobs upsert <path>`
- `allbert-cli jobs pause <name>`
- `allbert-cli jobs resume <name>`
- `allbert-cli jobs run <name>`
- `allbert-cli jobs remove <name>`

The job status surface includes recent outcome, last stop reason, and failure streak so you do not need to inspect JSONL files first.

## Skills and memory

Skills live under `~/.allbert/skills/`.

Memory lives under `~/.allbert/memory/`:

- `MEMORY.md` is the always-nearby index
- `daily/` holds dated notes
- `topics/`, `people/`, `projects/`, and `decisions/` are durable buckets for deeper notes

Chat history is not the durable store. Important facts need to be written into memory files.

## Files you should know

- `~/.allbert/config.toml`
- `~/.allbert/run/daemon.sock`
- `~/.allbert/logs/daemon.log`
- `~/.allbert/logs/daemon.debug.log`
- `~/.allbert/SOUL.md`
- `~/.allbert/USER.md`
- `~/.allbert/IDENTITY.md`
- `~/.allbert/TOOLS.md`
- `~/.allbert/jobs/definitions/`
- `~/.allbert/jobs/runs/`
- `~/.allbert/jobs/failures/`
- `~/.allbert/jobs/templates/`
- `~/.allbert/skills/`
- `~/.allbert/memory/`
- `~/.allbert/costs.jsonl`

## Current limitations

- source-based install only
- terminal-first and local-user-only
- local IPC only; no remote/network control plane
- interactive session state survives client reattach while the daemon is alive, but not a daemon restart
- no boot-time OS service install yet
- bundled job templates are intentionally disabled by default
- live provider use still depends on your network and API-key env vars
- final conversational closeout is still pending for v0.2, so `allbert-cli jobs ...` remains the clearest operator escape hatch even though prompt-native scheduling and explicit preview/confirm are now implemented

## More detail

See [docs/onboarding-and-operations.md](docs/onboarding-and-operations.md) for the operator walkthrough, config examples, daemon lifecycle guidance, jobs workflow, and troubleshooting.
