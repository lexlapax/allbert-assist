# Allbert

Allbert is a terminal-first personal assistant built around a small Rust kernel, markdown bootstrap files, markdown memory, skills, built-in tools, policy checks, cost tracking, first-class agents, intent routing, and a local daemon runtime.

v0.4 targets a technical source-based user. You build it from source, point it at an Anthropic or OpenRouter API key, complete a guided first-run setup flow, and then use `allbert-cli` as the primary entry point for REPL work, daemon lifecycle commands, recurring jobs, agent inspection, and strict AgentSkills-format skill management.

The daemon-backed jobs substrate, prompt-facing job tools, explicit preview-and-confirm flow for durable schedule mutation, first-class sub-agents, intent routing, generated `AGENTS.md` catalog, strict AgentSkills validation, install/update preview UX, and skill script execution policy are all part of the shipped v0.4 experience. You can manage recurring jobs through `allbert-cli jobs ...` or through normal conversation in the REPL, with the CLI preserved as the clearest operator escape hatch.

## What v0.4 includes

- a kernel that owns the agent loop, tools, memory, skills, policy, cost, and tracing
- a local daemon host with attachable REPL, CLI, and jobs channels
- daemon-backed REPL sessions with reconnectable in-memory session state while the daemon is alive
- a root agent per session plus bounded sub-agent spawning
- intent routing over `{task, chat, schedule, memory_query, meta}`
- generated `AGENTS.md` plus `allbert-cli agents list` for agent discovery
- markdown bootstrap personality files under `~/.allbert/`
- built-in tools for process exec, filesystem access, input, web fetch/search, skills, and memory
- explicit workspace trust through `fs_roots`
- daemon lifecycle commands under `allbert-cli daemon ...`
- recurring jobs under `allbert-cli jobs ...` and the `allbert-jobs` alias
- bundled disabled maintenance job templates
- strict AgentSkills-format skills installed under `~/.allbert/skills/installed/`
- `allbert-cli skills list|show|validate|install|update|remove|init`
- local-path and git-URL skill installs with plain-English preview and explicit confirmation
- `read_reference` and `run_skill_script` as the progressive-disclosure/runtime surfaces for skill resources

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

List registered agents:

```bash
cargo run -p allbert-cli -- agents list
```

List installed skills:

```bash
cargo run -p allbert-cli -- skills list
```

Show one installed skill:

```bash
cargo run -p allbert-cli -- skills show note-taker
```

Validate a skill tree before install:

```bash
cargo run -p allbert-cli -- skills validate examples/skills/note-taker/SKILL.md
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
- `/status` shows provider, model, root agent, last active agent stack, last resolved intent, setup state, trusted roots, daemon/jobs defaults, API-key presence, installed skill count, and trace mode
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

Agent inspection:

- `allbert-cli agents list`
- `cat ~/.allbert/AGENTS.md`

The job status surface includes recent outcome, last stop reason, and failure streak so you do not need to inspect JSONL files first.

Conversational scheduling examples:

- `what jobs do I have?`
- `schedule a daily review at 07:00`
- `schedule a weekly review on monday at 09:00`
- `run it now`
- `why did that job fail?`
- `pause it`
- `resume it`
- `delete it`

Common schedule forms the assistant understands well in v0.4:

- `@daily at HH:MM`
- `@weekly on monday at HH:MM`
- `every 2h`
- `once at 2026-04-20T16:00:00Z`

## Skills and memory

Canonical installed skills live under `~/.allbert/skills/installed/`. Incoming downloads and clones are quarantined under `~/.allbert/skills/incoming/` until you approve the preview.

Common skill commands:

- `cargo run -p allbert-cli -- skills list`
- `cargo run -p allbert-cli -- skills show <name>`
- `cargo run -p allbert-cli -- skills validate <path>`
- `cargo run -p allbert-cli -- skills install <path-or-git-url>`
- `cargo run -p allbert-cli -- skills update <name>`
- `cargo run -p allbert-cli -- skills remove <name>`
- `cargo run -p allbert-cli -- skills init <name>`

The bundled example skill is [examples/skills/note-taker/SKILL.md](examples/skills/note-taker/SKILL.md). It demonstrates the v0.4 shape: `SKILL.md` plus `references/` and `scripts/`.

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
- `~/.allbert/AGENTS.md`
- `~/.allbert/jobs/definitions/`
- `~/.allbert/jobs/runs/`
- `~/.allbert/jobs/failures/`
- `~/.allbert/jobs/templates/`
- `~/.allbert/skills/`
- `~/.allbert/skills/installed/`
- `~/.allbert/skills/incoming/`
- `~/.allbert/memory/`
- `~/.allbert/costs.jsonl`

## Current limitations

- source-based install only
- terminal-first and local-user-only
- local IPC only; no remote/network control plane
- interactive session state survives client reattach while the daemon is alive, but not a daemon restart
- sub-agent delegation is intentionally bounded to one nested level in v0.4
- no boot-time OS service install yet
- bundled job templates are intentionally disabled by default
- live provider use still depends on your network and API-key env vars
- conversational scheduling is optimized for the bounded schedule DSL used by v0.2/v0.3; raw cron remains an advanced escape hatch
- skill installs assume strict AgentSkills-format trees; Allbert does not ship a runtime migration helper for older relaxed skill layouts

## More detail

See [docs/onboarding-and-operations.md](docs/onboarding-and-operations.md) for the operator walkthrough, config examples, daemon lifecycle guidance, jobs workflow, and troubleshooting.
