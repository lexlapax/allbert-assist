# Allbert

Allbert is a terminal-first personal assistant built around a small Rust kernel, markdown bootstrap files, curated markdown memory, AgentSkills-format skills, built-in tools, policy checks, cost tracking, first-class agents, intent routing, and a local daemon runtime.

For repository development and contributor setup, see [DEVELOPMENT.md](/Users/spuri/projects/lexlapax/allbert-assist/DEVELOPMENT.md).

v0.7 is the current technical source-based release in this repo. You build it from source, point it at an Anthropic or OpenRouter API key, complete a guided first-run setup flow, and then use `allbert-cli` as the primary entry point for REPL work, daemon lifecycle commands, recurring jobs, agent inspection, strict AgentSkills-format skill management, curated-memory review, approval inspection, and channel administration.

The daemon-backed jobs substrate, prompt-facing job tools, explicit preview-and-confirm flow for durable schedule mutation, first-class sub-agents, intent routing, generated `AGENTS.md` catalog, strict AgentSkills validation, install/update preview UX, skill script execution policy, tiered curated memory, staged promotion/rejection, the shipped `memory-curator` skill, restart-durable sessions, daily cost-cap enforcement, operator-visible memory verification, the `Channel` trait, Telegram async approvals, explicit-intent web learning, and Telegram photo input for vision-capable models are all part of the shipped v0.7 experience. You can manage recurring jobs through `allbert-cli jobs ...` or through normal conversation in the REPL, with the CLI preserved as the clearest operator escape hatch. You can inspect, stage, promote, reject, and forget memory through both conversation and `allbert-cli memory ...`.

## What v0.7 includes

- a kernel that owns the agent loop, tools, memory, skills, policy, cost, and tracing
- a local daemon host with attachable REPL, CLI, jobs, and Telegram channels
- a first-class `Channel` abstraction with capability flags and a shipped Telegram pilot
- daemon-backed REPL sessions with reconnectable in-memory session state while the daemon is alive
- a root agent per session plus budget-governed sub-agent spawning
- intent routing over `{task, chat, schedule, memory_query, meta}`
- intent-guided routing defaults that shape prompts and tool preference without hard-gating tools
- generated `AGENTS.md` plus `allbert-cli agents list` for agent discovery
- markdown bootstrap personality files under `~/.allbert/`
- built-in tools for process exec, filesystem access, input, web fetch/search, skills, and memory
- explicit workspace trust through `fs_roots`
- daemon lifecycle commands under `allbert-cli daemon ...`
- channel lifecycle commands under `allbert-cli daemon channels ...`
- resumable daemon-backed sessions via `allbert-cli daemon resume ...`
- approval inspection via `allbert-cli approvals list|show`
- recurring jobs under `allbert-cli jobs ...` and the `allbert-jobs` alias
- bundled disabled maintenance job templates
- a safe fresh-profile default that preselects `memory-compile` only when you explicitly opt into recurring jobs during setup
- strict AgentSkills-format skills installed under `~/.allbert/skills/installed/`
- `allbert-cli skills list|show|validate|install|update|remove|init`
- local-path and git-URL skill installs with plain-English preview and explicit confirmation
- `read_reference` and `run_skill_script` as the progressive-disclosure/runtime surfaces for skill resources
- curated memory under `~/.allbert/memory/` with:
  - `MEMORY.md` as the near-at-hand catalog
  - `notes/` for approved durable memory
  - `staging/` for candidate learnings awaiting review
  - `manifest.json` plus `index/` as rebuildable kernel-owned metadata
- `allbert-cli memory status|search|staged|promote|reject|forget|rebuild-index`
- `allbert-cli memory verify` plus richer `memory status` health output
- a shipped `memory-curator` skill with review and explicit extraction workflows
- a turn-start daily cost cap with `/cost --override <reason>` for one-turn operator escape
- explicit-intent web learning through `record_as` on `web_search` and `fetch_url`
- Telegram async approvals via `/approve <approval-id>`, `/reject <approval-id>`, and `/override <reason>`
- Telegram photo input for vision-capable models, with downloaded photos stored as session artifacts under the parent session

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

Show the shipped memory curator skill:

```bash
cargo run -p allbert-cli -- skills show memory-curator
```

Check curated-memory status:

```bash
cargo run -p allbert-cli -- memory status
```

Verify curated-memory reconciliation state:

```bash
cargo run -p allbert-cli -- memory verify
```

Search approved durable memory:

```bash
cargo run -p allbert-cli -- memory search "postgres"
```

List staged learnings waiting for review:

```bash
cargo run -p allbert-cli -- memory staged list
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
- an optional daily cost cap in USD
- whether recurring jobs are enabled in this profile
- the default timezone for scheduled jobs
- whether to enable any bundled maintenance job templates immediately

Trusted roots matter: file tools are disabled outside the directories you explicitly trust. The wizard recommends the current working directory but does not auto-trust it.

When setup completes successfully:

- `config.toml` keeps the current profile/setup version and writes the latest defaults
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
- `/cost` shows session cost, today's recorded total, and cap state
- `/cost --override <reason>` bypasses the daily cost cap for exactly one turn
- `/exit` leaves the REPL without stopping the daemon

Unknown slash commands are rejected locally instead of being sent through to the model.

Memory examples that work well in v0.7:

- `what do you remember about Postgres?`
- `remember that we use Postgres for primary storage`
- `review what's staged`
- `promote that`
- `reject that`
- `forget that we use Postgres`

Daemon commands:

- `allbert-cli daemon status`
- `allbert-cli daemon start`
- `allbert-cli daemon stop`
- `allbert-cli daemon restart`
- `allbert-cli daemon resume --list`
- `allbert-cli daemon resume [--session <id>]`
- `allbert-cli daemon forget <session-id>`
- `allbert-cli daemon logs [--debug] [--follow] [--lines N]`
- `allbert-cli daemon channels list`
- `allbert-cli daemon channels status [telegram]`
- `allbert-cli daemon channels add telegram`
- `allbert-cli daemon channels remove telegram`

Approval inspection:

- `allbert-cli approvals list`
- `allbert-cli approvals show <approval-id>`
- `allbert-cli heartbeat show`
- `allbert-cli heartbeat edit`
- `allbert-cli heartbeat suggest [--channel <kind>]`

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

Common schedule forms the assistant understands well in v0.7:

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

The bundled example skill is [examples/skills/note-taker/SKILL.md](examples/skills/note-taker/SKILL.md). It demonstrates the v0.7 shape: `SKILL.md` plus `references/` and `scripts/`.
The shipped [skills/memory-curator/SKILL.md](skills/memory-curator/SKILL.md) skill is available on fresh profiles and packages the review/promotion workflow around the kernel-owned memory tools.

Curated memory lives under `~/.allbert/memory/`:

- `MEMORY.md` is the always-nearby catalog
- `daily/` holds dated recency notes
- `notes/` holds approved durable memory notes
- `staging/` holds candidate learnings awaiting review
- `manifest.json` inventories durable notes for the retriever
- `index/` holds rebuildable Tantivy artifacts
- `.trash/` keeps recently forgotten durable notes until retention expires

Common memory commands:

- `cargo run -p allbert-cli -- memory status`
- `cargo run -p allbert-cli -- memory verify`
- `cargo run -p allbert-cli -- memory search "postgres"`
- `cargo run -p allbert-cli -- memory staged list`
- `cargo run -p allbert-cli -- memory staged show <id>`
- `cargo run -p allbert-cli -- memory promote <id> --confirm`
- `cargo run -p allbert-cli -- memory reject <id> --reason "not durable"`
- `cargo run -p allbert-cli -- memory forget <path-or-query> --confirm`
- `cargo run -p allbert-cli -- memory rebuild-index --force`

Chat history is not the durable store. Durable learnings are staged first, then promoted explicitly into `notes/`.

If the turn-end staged-memory suffix feels noisy, set `memory.surface_staged_on_turn_end = false` in `~/.allbert/config.toml` and restart the REPL session.

If you are upgrading an existing v0.6 profile, see [docs/notes/v0.7-upgrade-2026-04-21.md](docs/notes/v0.7-upgrade-2026-04-21.md) for the new channel, approval, and image-input surfaces.

## Telegram pilot

Telegram is the first shipped non-REPL channel in v0.7.

Setup:

- add your bot token to `~/.allbert/secrets/telegram/bot_token`
- add one allowlisted chat id per line to `~/.allbert/config/channels.telegram.allowed_chats`
- enable the channel with `cargo run -p allbert-cli -- daemon channels add telegram`
- restart the daemon if it is already running

Useful operator commands:

- `cargo run -p allbert-cli -- daemon channels status telegram`
- `cargo run -p allbert-cli -- approvals list`
- `cargo run -p allbert-cli -- approvals show <approval-id>`

Telegram behaviour in v0.7:

- approvals are inspected from CLI/REPL but resolved only from Telegram
- `/approve <approval-id>` and `/reject <approval-id>` resolve pending async approvals
- `/override <reason>` retries one turn after a daily cost-cap refusal
- `/reset` starts a new Telegram session
- inbound photos work only when the active provider/model supports vision input
- downloaded photos are stored as session artifacts under `~/.allbert/sessions/<session-id>/artifacts/`

## Files you should know

- `~/.allbert/config.toml`
- `~/.allbert/run/daemon.sock`
- `~/.allbert/logs/daemon.log`
- `~/.allbert/logs/daemon.debug.log`
- `~/.allbert/secrets/telegram/bot_token`
- `~/.allbert/config/channels.telegram.allowed_chats`
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
- `~/.allbert/memory/notes/`
- `~/.allbert/memory/staging/`
- `~/.allbert/memory/manifest.json`
- `~/.allbert/memory/index/`
- `~/.allbert/memory/.trash/`
- `~/.allbert/costs.jsonl`
- `~/.allbert/sessions/<session-id>/artifacts/`

## Current limitations

- source-based install only
- terminal-first and local-user-only
- local IPC only; no remote/network control plane
- interactive session state now survives daemon restart through `daemon resume`, but incomplete tool invocations still rewind to the last completed turn boundary
- Telegram approval resolution is origin-channel-only in v0.7; cross-surface approval inbox work is deferred to v0.8
- sub-agent depth is budget-governed in v0.7 rather than fixed by nesting count
- no boot-time OS service install yet
- bundled job templates stay disabled by default except that fresh profiles which explicitly enable recurring jobs preselect `memory-compile`
- live provider use still depends on your network and API-key env vars
- Telegram image input is limited to photos; voice notes, audio, and image output are deferred
- conversational scheduling is optimized for the bounded schedule DSL used by v0.2/v0.3; raw cron remains an advanced escape hatch
- skill installs assume strict AgentSkills-format trees; Allbert does not ship a runtime migration helper for older relaxed skill layouts
- autonomous learnings are staged first; durable promotion and forgetting remain explicit review actions

## More detail

See [docs/onboarding-and-operations.md](docs/onboarding-and-operations.md) for the operator walkthrough, config examples, daemon lifecycle guidance, jobs workflow, curated-memory workflow, and troubleshooting.
Inspect heartbeat cadence and validation warnings:

```bash
cargo run -p allbert-cli -- heartbeat show
```
