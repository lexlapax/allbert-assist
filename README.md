# Allbert

Allbert is a terminal-first personal assistant built around a small Rust kernel, markdown bootstrap files, curated markdown memory, AgentSkills-format skills, built-in tools, policy checks, cost tracking, first-class agents, intent routing, and a local daemon runtime.

For repository development and contributor setup, see [DEVELOPMENT.md](DEVELOPMENT.md).

v0.13.0 is the current technical source-based release in this repo. You build it from source, complete a guided first-run setup flow, and then use `allbert-cli` as the primary entry point for TUI/classic REPL work, daemon lifecycle commands, recurring jobs, identity/session continuity, strict AgentSkills-format skill management, curated-memory review and recovery, approval inbox resolution, profile export/import, provider/model selection, telemetry/activity inspection, trace replay/export, local personalization adapters, settings changes, self-improvement review, skill authoring, scripting controls, and channel administration. Fresh profiles default to local Ollama with `gemma4` and the TUI; upgraded profiles preserve the classic REPL unless you opt in.

The daemon-backed jobs substrate, prompt-facing job tools, explicit preview-and-confirm flow for durable schedule mutation, first-class sub-agents, intent routing, generated `AGENTS.md` catalog, strict AgentSkills validation, install/update preview UX, skill script execution policy, tiered curated memory, staged promotion/rejection/reconsideration, the shipped `memory-curator` skill, restart-durable sessions, daily cost-cap enforcement, operator-visible memory verification, the `Channel` trait, Telegram async approvals and activity/status commands, cross-surface approval inbox resolution, identity-routed session continuity, explicit sync posture, profile export/import, `HEARTBEAT.md` cadence controls, explicit-intent web learning, Telegram photo input for vision-capable models, direct Anthropic/OpenRouter/OpenAI/Gemini/Ollama provider support, kernel-owned telemetry and activity snapshots, durable session trace/replay, file-based OTLP-JSON trace export, configurable TUI status-line items, typed settings changes, always-eligible memory routing, episode/fact recall tiers, the review-first personality digest seam, review-first local adapter training, source-checkout-bound self-improvement worktrees, `patch-approval` inbox items with bounded context, the `skill-author` natural-language authoring skill, skill provenance and enablement controls, and opt-in embedded Lua scripting are all part of the current v0.13.0 end-user experience.

## What v0.13.0 includes

- a kernel that owns the agent loop, tools, memory, skills, policy, cost, and tracing
- a local daemon host with attachable TUI, classic REPL, CLI, jobs, and Telegram channels
- a Ratatui/Crossterm TUI for fresh profiles plus classic Reedline fallback for upgrades
- daemon-owned telemetry through `/telemetry`, `allbert-cli telemetry --json`, and the TUI status line
- daemon-owned live activity through `/activity`, `allbert-cli activity [--json]`, Telegram `/activity`, and protocol v3 `ActivitySnapshot`
- durable session traces through `/trace`, `allbert-cli trace show|tail|list|show-span|export|gc`, Telegram structural trace summaries, and protocol v4 trace messages
- default `capture_messages = true` trace replay with unconditional secret redaction, bounded retention, disk-cap GC, and file-based OTLP-JSON export
- responsive in-flight TUI redraw, spinner/caret behavior, next-turn draft buffering, and modal input separation
- configurable status-line items for model, context, tokens, cost, memory, intent, skills, inbox, channel, trace, and adapter
- a typed settings hub through `/settings` and `allbert-cli settings`, with allowlisted path-preserving TOML edits
- a first-class `Channel` abstraction with capability flags and a shipped Telegram pilot
- daemon-backed sessions that route by identity across REPL, CLI, and Telegram surfaces
- a root agent per session plus budget-governed sub-agent spawning
- intent routing over `{task, chat, schedule, memory_query, meta}`
- intent-guided routing defaults that shape prompts and tool preference without hard-gating tools
- generated `AGENTS.md` plus `allbert-cli agents list` for agent discovery
- markdown bootstrap personality files under `~/.allbert/`
- built-in tools for process exec, filesystem access, input, web fetch/search, skills, and memory
- explicit workspace trust through `fs_roots`
- daemon lifecycle commands under `allbert-cli daemon ...`
- channel lifecycle commands under `allbert-cli daemon channels ...`
- identity management under `allbert-cli identity ...`
- lifecycle session management via `allbert-cli sessions ...`
- per-session approval inspection via `allbert-cli approvals list|show`
- daemon-backed approval inbox resolution via `allbert-cli inbox list|show|accept|reject`
- heartbeat inspection and editing via `allbert-cli heartbeat show|edit|suggest`
- profile export/import via `allbert-cli profile export|import`
- recurring jobs under `allbert-cli jobs ...` and the `allbert-jobs` alias
- bundled disabled maintenance job templates
- a safe fresh-profile default that preselects `memory-compile` only when you explicitly opt into recurring jobs during setup
- strict AgentSkills-format skills installed under `~/.allbert/skills/installed/`
- `allbert-cli skills list|show|validate|install|update|remove|init|enable|disable`
- local-path and git-URL skill installs with plain-English preview and explicit confirmation
- `read_reference` and `run_skill_script` as the progressive-disclosure/runtime surfaces for skill resources
- curated memory under `~/.allbert/memory/` with:
  - `MEMORY.md` as the near-at-hand catalog
  - `notes/` for approved durable memory
  - `staging/` for candidate learnings awaiting review
  - `manifest.json` plus `index/` as rebuildable kernel-owned metadata
- `allbert-cli memory status|stats|search|staged|routing|promote|reject|forget|restore|reconsider|recovery-gc|rebuild-index`
- `allbert-cli memory verify` plus richer `memory status` health output
- a shipped `memory-curator` skill with review and explicit extraction workflows
- configurable memory routing where `memory-curator` is always eligible but not always active
- explicit `episode` and `fact` memory search tiers that never bypass durable-memory review
- optional semantic retrieval seam, disabled by default and fake-provider-only in the current release
- optional `PERSONALITY.md` learned overlay loaded only when present, lower-authority than `SOUL.md`
- `allbert-cli learning digest --preview|--run` and `jobs template enable|disable personality-digest`
- local adapter training through `allbert-cli adapters training preview|start|cancel`, disabled by default and gated by trainer allowlists
- `adapter-approval` inbox items with eval summaries, loss curves, behavioral diffs, and explicit install-before-activation review
- single-slot local adapter activation through `allbert-cli adapters activate|deactivate|status|list|show|eval|loss|remove|history|gc`
- profile export excludes adapter artifacts by default; `--include-adapters` includes installed adapters plus `active.json` only
- self-improvement controls under `allbert-cli self-improvement config|diff|install|gc`
- isolated rebuild worktrees under `~/.allbert/worktrees/` with source-checkout detection and disk-cap-aware GC
- `patch-approval` inbox rendering for self-improvement diffs; acceptance records review and install remains a separate operator command
- `skills/rust-rebuild` for source-checkout-bound Rust patch proposals
- `skills/skill-author` seeded on first run, so natural-language skill authoring routes through the same install quarantine as external skills
- skill provenance (`external`, `local-path`, `git`, `self-authored`) surfaced in previews and `skills list`
- an opt-in Lua `ScriptingEngine` seam for JSON-in/JSON-out skill scripts with two-gate enablement, stdlib allowlist, deny floor, and execution/memory/output caps
- a turn-start daily cost cap with `/cost --override <reason>` for one-turn operator escape
- explicit-intent web learning through `record_as` on `web_search` and `fetch_url`
- direct provider clients for Anthropic, OpenRouter, OpenAI, Gemini, and local Ollama
- fresh-profile local-first defaults: `provider = "ollama"`, `model_id = "gemma4"`, and `base_url = "http://127.0.0.1:11434"`
- Telegram async approvals via `/approve <approval-id>`, `/reject <approval-id>`, `/override <reason>`, `/activity`, and compact `/status`, plus cross-surface resolution from CLI, TUI, and REPL inbox commands
- Telegram photo input for vision-capable models, with downloaded photos stored as session artifacts under the parent session

## Prerequisites

- Rust toolchain with `cargo`
- optional local Ollama if you want the fresh-profile default to work on the first live turn:
  - install Ollama separately
  - run `ollama run gemma4` before your first local-provider turn
- optional hosted-provider API keys:
  - `ANTHROPIC_API_KEY` for Anthropic
  - `OPENROUTER_API_KEY` for OpenRouter
  - `OPENAI_API_KEY` for OpenAI
  - `GEMINI_API_KEY` for Gemini

Allbert does not install Ollama and does not auto-pull `gemma4`; the operator owns local model installation. If you use the default Ollama/Gemma4 profile, no API key is required. If you switch to a hosted provider, export that provider's key before your first live hosted turn:

```bash
export ANTHROPIC_API_KEY=...
```

or

```bash
export OPENROUTER_API_KEY=...
```

or:

```bash
export OPENAI_API_KEY=...
export GEMINI_API_KEY=...
```

## Build and run

Start the configured interactive surface:

```bash
cargo run -p allbert-cli --
```

Force one surface for the current invocation:

```bash
cargo run -p allbert-cli -- repl --tui
cargo run -p allbert-cli -- repl --classic
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

Show memory counts and routing:

```bash
cargo run -p allbert-cli -- memory stats
cargo run -p allbert-cli -- memory routing show
```

Verify curated-memory reconciliation state:

```bash
cargo run -p allbert-cli -- memory verify
```

Search approved durable memory:

```bash
cargo run -p allbert-cli -- memory search "postgres"
```

Search working-history episodes or approved facts explicitly:

```bash
cargo run -p allbert-cli -- memory search "debugging decision" --tier episode
cargo run -p allbert-cli -- memory search "project storage" --tier fact
```

Show telemetry as JSON:

```bash
cargo run -p allbert-cli -- telemetry --json
```

Show self-improvement state and configure a source checkout:

```bash
cargo run -p allbert-cli -- self-improvement config show
cargo run -p allbert-cli -- self-improvement config set --source-checkout /path/to/allbert-assist
```

Preview the personality digest corpus without provider calls or writes:

```bash
cargo run -p allbert-cli -- learning digest --preview
```

List staged learnings waiting for review:

```bash
cargo run -p allbert-cli -- memory staged list
```

Show one installed skill:

```bash
cargo run -p allbert-cli -- skills show note-taker
```

Show the shipped skill author:

```bash
cargo run -p allbert-cli -- skills show skill-author
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
- whether to use the TUI or classic REPL as the default interactive surface
- an optional daily cost cap in USD
- whether recurring jobs are enabled in this profile
- the default timezone for scheduled jobs
- whether to enable any bundled maintenance job templates immediately
- whether to enable trace/replay, capture full message text, and use the default trace retention/disk caps
- whether to enable local adapter training, which trainer backend to allowlist, the local compute cap, and whether redacted trace excerpts may enter adapter training

Trusted roots matter: file tools are disabled outside the directories you explicitly trust. The wizard recommends the current working directory but does not auto-trust it.

When setup completes successfully:

- `config.toml` keeps the current profile/setup version and writes the latest defaults
- bootstrap files are updated with your confirmed values
- daemon/jobs defaults are written into config
- trace/replay defaults are written into config
- adapter-training defaults are written into config; existing profiles also get a safe path-preserving `[learning.adapter_training]` default-write when the daemon starts
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
- `/telemetry` shows live model, token, cost, memory, skill, inbox, and trace telemetry
- `/activity` shows the daemon-owned live phase, elapsed time, stuck hint, and next actions
- `/trace [show|show-span|tail|export|settings]` inspects durable session spans, tails completed spans, exports OTLP-JSON, or opens trace settings
- `/adapters [status|list|history]` inspects local personalization adapter state
- `/settings` lists, explains, sets, and resets supported profile settings
- `/statusline [show|enable|disable|toggle <item>|add <item>|remove <item>]` inspects or changes configured TUI status-line items
- `/inbox`, `/skills`, `/memory staged`, and `/self-improvement` expose review workflows without leaving the TUI/REPL
- `/memory stats` shows durable, staged, episode, and fact counts
- `/memory routing` shows memory routing policy
- `/model` shows the active session model
- `/model <anthropic|openrouter|openai|gemini|ollama> <model_id> [api_key_env]` switches model/provider for the attached session only
- `/model ollama gemma4` switches the attached session to local Ollama without requiring an API key
- `/cost` shows session cost, today's recorded total, and cap state
- `/cost --override <reason>` bypasses the daily cost cap for exactly one turn
- `/exit` leaves the REPL without stopping the daemon

Unknown slash commands are rejected locally instead of being sent through to the model, and close typos get a short suggestion.

Memory examples that work well in v0.13:

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
- `allbert-cli daemon logs [--debug] [--follow] [--lines N]`
- `allbert-cli daemon channels list`
- `allbert-cli daemon channels status [telegram]`
- `allbert-cli daemon channels add telegram`
- `allbert-cli daemon channels remove telegram`
- `allbert-cli sessions list [--identity <id>] [--channel <kind>] [--limit N] [--json]`
- `allbert-cli sessions show <session-id>`
- `allbert-cli sessions resume <session-id>`
- `allbert-cli sessions forget <session-id>`

Approval inspection:

- `allbert-cli approvals list`
- `allbert-cli approvals show <approval-id>`
- `allbert-cli heartbeat show`
- `allbert-cli heartbeat edit`
- `allbert-cli heartbeat suggest [--channel <kind>]`

Jobs commands:

- `allbert-cli jobs list`
- `allbert-cli jobs status <name>`
- `allbert-cli jobs template enable personality-digest`
- `allbert-cli jobs template disable personality-digest`
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

Common schedule forms the assistant understands well:

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

The bundled example skill is [examples/skills/note-taker/SKILL.md](examples/skills/note-taker/SKILL.md). It demonstrates the current AgentSkills shape: `SKILL.md` plus `references/` and `scripts/`.
The shipped [skills/memory-curator/SKILL.md](skills/memory-curator/SKILL.md) skill is available on fresh profiles and packages the review/promotion workflow around the kernel-owned memory tools.
The shipped [skills/skill-author/SKILL.md](skills/skill-author/SKILL.md) skill is also available on fresh profiles and helps draft new AgentSkills-format skills through natural language while preserving the install quarantine.

`skills list` includes a `Source` column. Existing skills without provenance load as `external`; skills drafted by `skill-author` carry `self-authored`.

Curated memory lives under `~/.allbert/memory/`:

- `MEMORY.md` is the always-nearby catalog
- `daily/` holds dated recency notes
- `notes/` holds approved durable memory notes
- `staging/` holds candidate learnings awaiting review
- `manifest.json` inventories durable notes for the retriever
- `index/` holds rebuildable Tantivy artifacts
- `index/semantic/` holds optional derived semantic artifacts when enabled
- `.trash/` keeps recently forgotten durable notes until retention expires

Common memory commands:

- `cargo run -p allbert-cli -- memory status`
- `cargo run -p allbert-cli -- memory stats`
- `cargo run -p allbert-cli -- memory verify`
- `cargo run -p allbert-cli -- memory search "postgres"`
- `cargo run -p allbert-cli -- memory search "debugging decision" --tier episode`
- `cargo run -p allbert-cli -- memory search "project storage" --tier fact`
- `cargo run -p allbert-cli -- memory routing show`
- `cargo run -p allbert-cli -- memory staged list`
- `cargo run -p allbert-cli -- memory staged show <id>`
- `cargo run -p allbert-cli -- memory promote <id> --confirm`
- `cargo run -p allbert-cli -- memory reject <id> --reason "not durable"`
- `cargo run -p allbert-cli -- memory forget <path-or-query> --confirm`
- `cargo run -p allbert-cli -- memory rebuild-index --force`

Chat history is not the durable store. Episode recall is searchable working history, not approved durable memory. Durable learnings are staged first, then promoted explicitly into `notes/`; fact-tier recall is approved only after its parent note is durable.

If the turn-end staged-memory suffix feels noisy, set `memory.surface_staged_on_turn_end = false` in `~/.allbert/config.toml` and restart the REPL session.

## Self-improvement and scripting

Source-checkout-bound self-improvement commands:

- `cargo run -p allbert-cli -- self-improvement config show`
- `cargo run -p allbert-cli -- self-improvement config set --source-checkout <path>`
- `cargo run -p allbert-cli -- self-improvement gc --dry-run`
- `cargo run -p allbert-cli -- self-improvement diff <approval-id>`
- `cargo run -p allbert-cli -- self-improvement install <approval-id>`

Allbert never swaps its own binary. `self-improvement install` applies an accepted patch to your configured source checkout and prints the `cargo install --path crates/allbert-cli` plus daemon restart hint for you to run deliberately.

Lua skill scripts are disabled by default. Enable them only when you want the embedded JSON-in/JSON-out runtime:

```toml
[scripting]
engine = "lua"

[security]
exec_allow = ["bash", "python", "lua"]
```

If you are upgrading an existing profile, see [docs/notes/v0.13-upgrade-2026-04-26.md](docs/notes/v0.13-upgrade-2026-04-26.md), [docs/notes/v0.12.2-upgrade-2026-04-25.md](docs/notes/v0.12.2-upgrade-2026-04-25.md), [docs/notes/v0.12.1-upgrade-2026-04-25.md](docs/notes/v0.12.1-upgrade-2026-04-25.md), [docs/notes/v0.12-upgrade-2026-04-25.md](docs/notes/v0.12-upgrade-2026-04-25.md), [docs/notes/v0.11-upgrade-2026-04-24.md](docs/notes/v0.11-upgrade-2026-04-24.md), and [docs/notes/v0.10-upgrade-2026-04-24.md](docs/notes/v0.10-upgrade-2026-04-24.md). Users coming from v0.8 or earlier should also review [docs/notes/v0.9-upgrade-2026-04-24.md](docs/notes/v0.9-upgrade-2026-04-24.md) and [docs/notes/v0.8-upgrade-2026-04-23.md](docs/notes/v0.8-upgrade-2026-04-23.md).

## Telegram channel

Telegram is the first shipped non-REPL channel in v0.8.

Setup:

- add your bot token to `~/.allbert/secrets/telegram/bot_token`
- add one allowlisted chat id per line to `~/.allbert/config/channels.telegram.allowed_chats`
- enable the channel with `cargo run -p allbert-cli -- daemon channels add telegram`
- restart the daemon if it is already running

Useful operator commands:

- `cargo run -p allbert-cli -- daemon channels status telegram`
- `cargo run -p allbert-cli -- inbox list`
- `cargo run -p allbert-cli -- inbox show <approval-id>`
- `cargo run -p allbert-cli -- inbox accept <approval-id> --reason "approved from shell"`

Telegram behaviour in v0.13:

- pending approvals can be resolved from Telegram, CLI, TUI, or an attached classic REPL inbox
- `/activity` and compact `/status` render daemon-owned activity without raw prompt, secret, or full tool-output data
- `/trace last` and `/trace span <span-id>` render compact, redacted structural trace summaries; full trace content stays on local disk
- `/approve <approval-id>` and `/reject <approval-id>` still resolve pending async approvals from Telegram itself
- `/override <reason>` still retries one turn after a daily cost-cap refusal, and the same `cost-cap-override` item appears in the shared inbox
- `/reset` starts a new Telegram session
- typing indication and markdown-aware replies are best-effort channel presentation; daemon state remains authoritative
- inbound photos work only when the active provider/model supports image input; Anthropic, OpenAI, Gemini, and supported local Ollama vision models are enabled through the provider capability gate
- downloaded photos are stored as session artifacts under `~/.allbert/sessions/<session-id>/artifacts/`

## Files you should know

- `~/.allbert/config.toml`
- `~/.allbert/config.toml.last-good`
- `~/.allbert/run/daemon.sock`
- `~/.allbert/logs/daemon.log`
- `~/.allbert/logs/daemon.debug.log`
- `~/.allbert/secrets/telegram/bot_token`
- `~/.allbert/config/channels.telegram.allowed_chats`
- `~/.allbert/identity/user.md`
- `~/.allbert/SOUL.md`
- `~/.allbert/USER.md`
- `~/.allbert/IDENTITY.md`
- `~/.allbert/TOOLS.md`
- `~/.allbert/PERSONALITY.md` (optional learned overlay)
- `~/.allbert/AGENTS.md`
- `~/.allbert/HEARTBEAT.md`
- `~/.allbert/daemon.lock`
- `~/.allbert/jobs/definitions/`
- `~/.allbert/jobs/runs/`
- `~/.allbert/jobs/failures/`
- `~/.allbert/jobs/templates/`
- `~/.allbert/learning/personality-digest/`
- `~/.allbert/self-improvement/`
- `~/.allbert/self-improvement/history.md`
- `~/.allbert/worktrees/`
- `~/.allbert/skills/`
- `~/.allbert/skills/installed/`
- `~/.allbert/skills/incoming/`
- `~/.allbert/memory/`
- `~/.allbert/memory/notes/`
- `~/.allbert/memory/staging/`
- `~/.allbert/memory/trash/`
- `~/.allbert/memory/reject/`
- `~/.allbert/memory/manifest.json`
- `~/.allbert/memory/index/`
- `~/.allbert/memory/index/semantic/`
- `~/.allbert/costs.jsonl`
- `~/.allbert/sessions/<session-id>/artifacts/`
- `~/.allbert/sessions/<session-id>/trace.jsonl`
- `~/.allbert/sessions/<session-id>/trace-*.jsonl.gz`
- `~/.allbert/sessions/<session-id>/current_spans/`

## Current limitations

- source-based install only
- terminal-first and local-user-only
- local IPC only; no remote/network control plane
- interactive session state now survives daemon restart through `sessions resume`, but incomplete tool invocations still rewind to the last completed turn boundary
- unsolicited heartbeat delivery is currently limited to Telegram; `repl`, `cli`, and `jobs` remain inspect-and-act surfaces rather than proactive delivery targets
- daily cost caps remain per-device rather than globally aggregated across synced machines
- sub-agent depth is budget-governed rather than fixed by nesting count
- no boot-time OS service install yet
- bundled job templates stay disabled by default except that fresh profiles which explicitly enable recurring jobs preselect `memory-compile`
- hosted-provider use still depends on your network and API-key env vars
- local Ollama use depends on a running Ollama service and a pulled local model; Allbert does not install Ollama or run `ollama pull` for you
- Telegram image input is limited to photos; voice notes, audio, and image output are deferred
- conversational scheduling is optimized for the bounded schedule DSL used by v0.2/v0.3; raw cron remains an advanced escape hatch
- skill installs assume strict AgentSkills-format trees; Allbert does not ship a runtime migration helper for older relaxed skill layouts
- autonomous learnings are staged first; durable promotion and forgetting remain explicit review actions
- semantic retrieval ships as an off-by-default derived index with only the fake deterministic provider
- personality digest remains a review-first, provider-free deterministic markdown overlay; local adapter training is optional, disabled by default, and requires a compatible local backend
- hosted providers ignore active adapters; only local Ollama activation is supported in v0.13
- `rust-rebuild` requires a local source checkout with the pinned Rust toolchain; binary-drop users can still use skill authoring and Lua scripting
- Lua scripting is off by default and intentionally limited to JSON-in/JSON-out transforms with no host tool bridge
- Ctrl-C does not cancel an active turn yet; the turn continues and the UI says so
- trace export is file-based only; Allbert does not ship a network OTLP exporter

## More detail

See [docs/onboarding-and-operations.md](docs/onboarding-and-operations.md) for the operator walkthrough, config examples, daemon lifecycle guidance, jobs workflow, curated-memory workflow, continuity workflow, and troubleshooting. Focused guides: [TUI](docs/operator/tui.md), [telemetry/activity](docs/operator/telemetry.md), [tracing](docs/operator/tracing.md), [adaptive memory](docs/operator/adaptive-memory.md), [personality digest](docs/operator/personality-digest.md), [personalization](docs/operator/personalization.md), [self-improvement](docs/operator/self-improvement.md), [skill authoring](docs/operator/skill-authoring.md), [Telegram](docs/operator/telegram.md), and [scripting](docs/operator/scripting.md). For sync posture and heartbeat policy, see [docs/operator/continuity.md](docs/operator/continuity.md) and [docs/operator/heartbeat.md](docs/operator/heartbeat.md).
Inspect heartbeat cadence and validation warnings:

```bash
cargo run -p allbert-cli -- heartbeat show
```
