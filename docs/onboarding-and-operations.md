# Allbert v0.12 Onboarding and Operations

This guide is the operator reference for the source-based v0.12 release.

## Quickstart

1. Install Ollama separately and run `ollama run gemma4` if you want the fresh-profile local default to work on the first live turn.
2. Export a hosted-provider API key only if you plan to use Anthropic, OpenRouter, OpenAI, or Gemini.
3. Run `cargo run -p allbert-cli --`.
4. Complete the guided setup flow.
5. Confirm daemon/session state with `/status` or `/telemetry`.
6. Use `allbert-cli daemon status`, `allbert-cli telemetry --json`, `allbert-cli jobs list`, `allbert-cli memory stats`, and `allbert-cli memory routing show` as needed.
7. Inspect the current agent catalog with `allbert-cli agents list` and the shipped curator and authoring flows with `allbert-cli skills show memory-curator` and `allbert-cli skills show skill-author`.
8. If you want source-checkout-bound self-improvement, pin a checkout with `allbert-cli self-improvement config set --source-checkout <path>`.

## Guided setup

On first run, Allbert creates `~/.allbert/` and asks for:

- your preferred name
- your timezone, with a guessed default when available
- how Allbert should usually work with you, with a practical default
- your current priorities, with a safe fallback if you have none to record yet
- optional assistant identity edits for Allbert itself
- the default model provider and model id, defaulting to local `ollama` / `gemma4` on fresh profiles
- an API-key environment variable for hosted providers, or a local base URL for Ollama
- trusted filesystem roots, with the current project directory offered as the default first root
- whether the CLI should auto-start the daemon when needed
- whether the default interactive surface should be TUI or classic REPL
- an optional daily cost cap in USD
- whether recurring jobs are enabled for this profile
- the default timezone for scheduled jobs
- whether to enable any bundled maintenance job templates immediately

Type `/cancel` at any setup prompt to abort setup cleanly.

If setup completes:

- `config.toml` is updated with the current profile/setup version and latest defaults
- `USER.md` is filled with the confirmed profile values
- `IDENTITY.md` is updated only if you chose to customize assistant identity
- daemon/jobs defaults are written into config
- selected bundled job templates are copied into `~/.allbert/jobs/definitions/`
- `BOOTSTRAP.md` is deleted

If setup is cancelled:

- Allbert exits before opening the REPL
- `setup.version` stays incomplete
- `BOOTSTRAP.md` remains in place

## Trusted roots and file tools

`fs_roots` is the allowlist for file tools.

Allbert does not auto-trust your current directory. The setup wizard recommends it, but you must opt in.

If `fs_roots` is empty:

- file tools remain disabled outside Allbert's own internal storage
- startup prints a warning
- `/status` shows `(none)` for trusted roots

This is intentional. Allbert still prefers explicit workspace trust over permissive defaults.

## Example config

`~/.allbert/config.toml` is written automatically. A typical fresh v0.12 file looks like:

```toml
trace = false

[model]
provider = "ollama"
model_id = "gemma4"
base_url = "http://127.0.0.1:11434"
max_tokens = 4096
context_window_tokens = 0 # 0 means unknown; set explicitly when your model/window is known

[setup]
version = 4

[daemon]
log_retention_days = 7
session_max_age_days = 30
auto_spawn = true

[sessions]
cross_channel_routing = "inherit"

[channels]
approval_timeout_s = 3600
approval_inbox_retention_days = 30

[channels.telegram]
enabled = false
min_interval_ms_per_chat = 1200
min_interval_ms_global = 40

[jobs]
enabled = false
max_concurrent_runs = 1
default_timeout_s = 600
default_timezone = "America/Los_Angeles"

[repl]
ui = "tui"
show_inbox_on_attach = true

[repl.tui]
mouse = true
max_transcript_events = 500

[repl.tui.status_line]
enabled = true
items = ["model", "context", "tokens", "cost", "memory", "intent", "skills", "inbox", "channel", "trace"]

[self_improvement]
source_checkout = ""
worktree_root = "~/.allbert/worktrees"
max_worktree_gb = 10
install_mode = "apply-to-current-branch"
keep_rejected_worktree = false

[scripting]
engine = "disabled"
max_execution_ms = 1000
max_memory_kb = 65536
max_output_bytes = 1048576
allow_stdlib = ["string", "math", "table"]
deny_stdlib = ["io", "os", "package", "require", "debug", "coroutine"]

[memory]
prefetch_enabled = true
prefetch_default_limit = 5
refresh_after_external_evidence = true
max_refreshes_per_turn = 1
max_synopsis_bytes = 8192
max_memory_md_head_bytes = 2048
max_daily_head_bytes = 2048
max_daily_tail_bytes = 1024
max_ephemeral_summary_bytes = 2048
max_prefetch_snippets = 5
max_prefetch_snippet_bytes = 512
max_ephemeral_bytes = 32768
max_staged_entries_per_turn = 5
max_subagent_snippets = 3
staged_entry_ttl_days = 90
staged_total_cap = 500
rejected_retention_days = 30
trash_retention_days = 30
index_auto_rebuild = true
default_search_limit = 10
default_daily_recency_days = 2
max_journal_tool_output_bytes = 4096
surface_staged_on_turn_end = true

[memory.routing]
mode = "always_eligible"
always_eligible_skills = ["memory-curator"]
auto_activate_intents = ["memory_query"]
auto_activate_cues = ["remember", "recall", "what do you remember", "review staged", "promote that", "forget"]

[memory.episodes]
enabled = true
prefetch_enabled = false
episode_lookback_days = 30
max_episode_summaries = 10
max_episode_hits = 5

[memory.facts]
enabled = true
max_facts_per_entry = 12

[memory.semantic]
enabled = false
provider = "none"
embedding_model = ""
hybrid_weight = 0.35

[learning]
enabled = false

[learning.personality_digest]
enabled = false
schedule = "@weekly on sunday at 18:00"
output_path = "PERSONALITY.md"
include_tiers = ["durable", "fact"]
include_episodes = true
episode_lookback_days = 30
max_episode_summaries = 10
max_input_bytes = 24576
max_output_bytes = 4096

[security]
exec_allow = ["bash", "python"]
exec_deny = ["sh", "zsh", "fish", "ruby", "perl"]
fs_roots = ["/absolute/path/to/workspace"]
auto_confirm = false

[security.web]
allow_hosts = []
deny_hosts = []
timeout_s = 15

[limits]
daily_usd_cap = 5.0
max_turns = 8
max_tool_calls_per_turn = 16
max_tool_output_bytes_per_call = 8192
max_tool_output_bytes_total = 65536
max_bootstrap_file_bytes = 2048
max_prompt_bootstrap_bytes = 6144
max_prompt_memory_bytes = 4096
max_skill_args_bytes = 2048
```

Hosted providers use the same `[model]` table with an API-key env var:

```toml
[model]
provider = "openai"
model_id = "gpt-5.4-mini"
api_key_env = "OPENAI_API_KEY"
max_tokens = 4096
```

Supported provider labels are `anthropic`, `openrouter`, `openai`, `gemini`, and `ollama`. Ollama is keyless and uses `base_url`; hosted providers use `api_key_env`.

The CLI may override some of this for the current interactive session:

- `--trace` enables daemon debug logging for the running daemon
- `--yes` enables session-only auto-confirm for the attached REPL session
- `repl --tui` opens the TUI for this invocation
- `repl --classic` opens the classic Reedline REPL for this invocation
- add `--save` to persist the selected `repl.ui`

## TUI and REPL usage

Fresh profiles use the TUI. Upgraded profiles keep classic REPL unless setup/config or `allbert-cli repl --tui --save` opts in.

TUI controls:

- type a message and press Enter to send it
- use slash commands exactly as in classic REPL
- Ctrl-D exits
- Ctrl-C reminds you to type `/exit` rather than stopping the daemon
- confirmation modals accept `y`, `n`, and `a` for allow-session when the action is not durable

Useful REPL commands:

- `/h`
  Alias for `/help`.
- `/help`
  Shows the command list.
- `/s`
  Alias for `/status`.
- `/status`
  Shows provider, model, root agent, last active agent stack, last resolved intent, API-key env presence or `not required`, setup version, bootstrap pending state, trusted roots, daemon auto-spawn, jobs enablement, jobs timezone, skill count, and trace mode.
- `/telemetry`
  Shows live model, token, cost, memory, skill, inbox, and trace telemetry.
- `/statusline [show|enable|disable|toggle <item>|add <item>|remove <item>]`
  Inspects or changes configured TUI status-line items.
- `/memory stats`
  Shows durable, staged, episode, and fact counts.
- `/memory routing`
  Shows the current memory routing policy.
- `/setup`
  Reruns guided setup. This updates config/bootstrap state and reloads daemon defaults plus job definitions for the current daemon session.
- `/model`
  Shows the active session model configuration.
- `/model <anthropic|openrouter|openai|gemini|ollama> <model_id> [api_key_env]`
  Switches provider/model for the attached session only.
- `/model ollama gemma4`
  Switches the attached session to local Ollama without requiring an API key and uses the default Ollama base URL.
- `/cost`
  Shows session cost, today's recorded total, and the current daily cap state from `~/.allbert/costs.jsonl`.
- `/cost --override <reason>`
  Arms a one-turn override for the daily cost cap and records the reason in trace output.
- `/cost --turn-budget <usd>`
  Sets a one-turn USD budget override for the next root turn.
- `/cost --turn-time <seconds>`
  Sets a one-turn time budget override for the next root turn.
- `/exit`
  Leaves the REPL without stopping the daemon.

Unknown slash commands are rejected locally with a short hint to use `/help`; they are not forwarded to the model.

For curated-memory review, the most useful operator commands are:

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

And in normal conversation:

- `what do you remember about Postgres?`
- `remember that we use Postgres for primary storage`
- `review what's staged`
- `promote that`
- `reject that`
- `forget that we use Postgres`

Scheduled job failures are surfaced live to attached REPL clients as one-line notices, and they also remain recorded durably under `~/.allbert/jobs/failures/`.

If the turn-end staged-memory suffix feels too noisy for your workflow, set `memory.surface_staged_on_turn_end = false` in `~/.allbert/config.toml` and restart the attached REPL session.

Episode search is working-history recall, not approved durable memory. Fact search returns facts only after their parent note is promoted into durable memory. Semantic retrieval is off by default; the current release ships the fake deterministic semantic provider for validation and keeps real embedding adapters as future additive work.

## Daemon lifecycle

The primary operator surface is `allbert-cli`.

Daemon commands:

- `cargo run -p allbert-cli -- daemon status`
- `cargo run -p allbert-cli -- daemon start`
- `cargo run -p allbert-cli -- daemon stop`
- `cargo run -p allbert-cli -- daemon restart`
- `cargo run -p allbert-cli -- daemon logs [--debug] [--follow] [--lines N]`
- `cargo run -p allbert-cli -- daemon channels list`
- `cargo run -p allbert-cli -- daemon channels status [telegram]`
- `cargo run -p allbert-cli -- daemon channels add telegram`
- `cargo run -p allbert-cli -- daemon channels remove telegram`
- `cargo run -p allbert-cli -- sessions list [--identity <id>] [--channel <kind>] [--limit N] [--json]`
- `cargo run -p allbert-cli -- sessions show <session-id>`
- `cargo run -p allbert-cli -- sessions resume <session-id>`
- `cargo run -p allbert-cli -- sessions forget <session-id>`

Agent commands:

- `cargo run -p allbert-cli -- agents list`

Approval commands:

- `cargo run -p allbert-cli -- approvals list`
- `cargo run -p allbert-cli -- approvals show <approval-id>`
- `cargo run -p allbert-cli -- inbox list`
- `cargo run -p allbert-cli -- inbox show <approval-id>`
- `cargo run -p allbert-cli -- inbox accept <approval-id> [--reason <text>]`
- `cargo run -p allbert-cli -- inbox reject <approval-id> [--reason <text>]`
- `cargo run -p allbert-cli -- heartbeat show`
- `cargo run -p allbert-cli -- heartbeat edit`
- `cargo run -p allbert-cli -- heartbeat suggest [--channel <kind>]`

`allbert-cli agents list` prints the same catalog the kernel writes to `~/.allbert/AGENTS.md`.

Notes:

- `daemon stop` is explicit and bounded graceful. It stops new work, interrupts remaining scheduled runs if needed, and records interrupted runs as non-success outcomes.
- Ctrl-C in the REPL detaches the client but does not stop the daemon.
- `daemon logs --debug --follow` is the quickest way to watch daemon-side diagnostics live.
- `daemon status` now includes daemon lock ownership details plus whether the configured model API-key env var is visible to the running daemon process.
- Continuity/sync posture and artifact categories are documented in `docs/operator/continuity.md`.
- `HEARTBEAT.md` field reference and warning semantics are documented in `docs/operator/heartbeat.md`.

## Telegram channel

Telegram first shipped as the non-REPL channel in v0.8 and remains part of the v0.12 end-user release.

Setup:

1. Put your bot token in `~/.allbert/secrets/telegram/bot_token`.
2. Put one allowlisted chat id per line in `~/.allbert/config/channels.telegram.allowed_chats`.
3. Run `cargo run -p allbert-cli -- daemon channels add telegram`.
4. Restart the daemon if it is already running.
5. Confirm the runtime state with `cargo run -p allbert-cli -- daemon channels status telegram`.

Operational notes:

- CLI, REPL, TUI, and Telegram can all resolve pending approvals through the shared inbox in v0.12.
- `/approve <approval-id>` accepts an async approval from Telegram itself.
- `/reject <approval-id>` rejects an async approval from Telegram itself.
- `/override <reason>` retries one turn after a daily cost-cap refusal and mirrors the same `cost-cap-override` item into the inbox.
- `/reset` forces a new Telegram session.
- incoming photos work only when the active provider/model supports image input; Anthropic, OpenAI, Gemini, and supported local Ollama vision models are enabled through the provider capability gate
- downloaded photos are stored under `~/.allbert/sessions/<session-id>/artifacts/`
- those photos are session artifacts, not durable memory, and archive/forget with the parent session

## Continuity across devices

v0.12 treats profile continuity as an explicit operator workflow rather than an accidental side effect of copying `~/.allbert/`.

Recommended second-device flow:

1. On the source device, export with `cargo run -p allbert-cli -- profile export /path/to/profile.tgz`.
2. Copy the archive to the destination device.
3. Import with `cargo run -p allbert-cli -- profile import /path/to/profile.tgz --overlay` for normal merges, or `--replace --yes` when you want a clean replacement.
4. Recheck runtime state with `cargo run -p allbert-cli -- daemon status`, `cargo run -p allbert-cli -- identity show`, `cargo run -p allbert-cli -- inbox list`, `cargo run -p allbert-cli -- heartbeat show`, and `cargo run -p allbert-cli -- memory verify`.

For file-level sync posture and excludes, see `docs/operator/continuity.md`.

## Jobs workflow

Jobs are daemon-owned and non-interactive by default.

Job lifecycle management is authoritative through the CLI surfaces below, and daemon-backed prompt job tools now make conversational scheduling a first-class path too. Durable schedule mutation goes through an explicit preview-and-confirm step in interactive sessions. The CLI remains the clearest operator surface, but it is no longer the only trustworthy way to manage recurring jobs.

Canonical commands:

- `cargo run -p allbert-cli -- jobs list`
- `cargo run -p allbert-cli -- jobs status <name>`
- `cargo run -p allbert-cli -- jobs template enable personality-digest`
- `cargo run -p allbert-cli -- jobs template disable personality-digest`
- `cargo run -p allbert-cli -- jobs upsert <path>`
- `cargo run -p allbert-cli -- jobs pause <name>`
- `cargo run -p allbert-cli -- jobs resume <name>`
- `cargo run -p allbert-cli -- jobs run <name>`
- `cargo run -p allbert-cli -- jobs remove <name>`

The shorter alias still works:

- `cargo run -p allbert-jobs -- list`
- `cargo run -p allbert-jobs -- status <name>`

Job definitions live in `~/.allbert/jobs/definitions/` as markdown with YAML frontmatter. Mutable state lives in `~/.allbert/jobs/state/`, run history in `~/.allbert/jobs/runs/`, failures in `~/.allbert/jobs/failures/`, and bundled disabled starter templates in `~/.allbert/jobs/templates/`.

`jobs status` surfaces:

- enabled/paused/running state
- schedule and timezone
- model override when present
- next due time
- last run id
- last outcome
- last stop reason when present
- failure streak

Conversational scheduling works best when you ask plainly. Good examples:

- `what jobs do I have?`
- `schedule a daily review at 07:00`
- `schedule a weekly review on monday at 09:00`
- `run it now`
- `why did that job fail?`
- `pause it`
- `resume it`
- `delete it`

Common schedule forms the assistant should compile naturally in v0.12:

- `@daily at HH:MM`
- `@weekly on monday at HH:MM`
- `every 2h`
- `once at 2026-04-20T16:00:00Z`

When you create, update, pause, resume, or remove a job from normal conversation, Allbert shows a durable-change preview and waits for explicit confirmation before persisting it.

## Bundled maintenance jobs

v0.12 seeds these bundled templates:

- `daily-brief`
- `weekly-review`
- `memory-compile`
- `trace-triage`
- `system-health-check`
- `personality-digest`

The setup wizard can enable selected templates for you. Fresh profiles that explicitly opt into recurring jobs preselect `memory-compile`, because it now stages candidate learnings instead of writing durable notes directly. `personality-digest` stays opt-in and disabled until you enable its template. If you skip a template there, it stays available under `~/.allbert/jobs/templates/` until you copy or upsert it yourself.

## Skills and memory

The canonical installed skill root in v0.12 is `~/.allbert/skills/installed/`.

Quarantine lives under `~/.allbert/skills/incoming/`; fetched or copied skills stay there until you approve the preview.

Skill commands:

- `cargo run -p allbert-cli -- skills list`
- `cargo run -p allbert-cli -- skills show <name>`
- `cargo run -p allbert-cli -- skills validate <path>`
- `cargo run -p allbert-cli -- skills install <path-or-git-url>`
- `cargo run -p allbert-cli -- skills update <name>`
- `cargo run -p allbert-cli -- skills remove <name>`
- `cargo run -p allbert-cli -- skills init <name>`

`skills list` is the quickest operator view of installed skills. `skills show <name>` prints the installed path, allowed tools, scripts, references, assets, and install metadata such as source kind and resolved commit.

Skill install/update preview shows:

- name and description
- source identity
- tree SHA-256
- declared agents
- declared allowed tools
- declared scripts with interpreter, path, and SHA-256
- the first lines of `SKILL.md`

v0.12 expects strict AgentSkills-format skill trees at install time. `skills validate` is the preflight tool; Allbert does not ship a runtime migration helper for older relaxed skill layouts.

In v0.12, skills can also preview:

- `intents:` metadata to hint the intent router
- `agents:` metadata to contribute namespaced sub-agents

The active agent roster is written to `~/.allbert/AGENTS.md` and included in the bootstrap prompt bundle.

Fresh profiles also seed the shipped `memory-curator` and `skill-author` skills. `memory-curator` is the first-party review surface around the kernel-owned memory tools; `skill-author` is the natural-language path for drafting new AgentSkills-format skills.

- `cargo run -p allbert-cli -- skills list`
- `cargo run -p allbert-cli -- skills show memory-curator`
- `cargo run -p allbert-cli -- skills show skill-author`

`skills list` includes a `Source` column. Existing skills without provenance load as `external`; drafts created by `skill-author` land in `~/.allbert/skills/incoming/<draft-name>/` with `provenance: self-authored` and still require install preview plus confirmation.

Curated memory is durable and markdown-grounded:

- `~/.allbert/memory/MEMORY.md`
- `~/.allbert/memory/daily/`
- `~/.allbert/memory/notes/`
- `~/.allbert/memory/staging/`
- `~/.allbert/memory/manifest.json`
- `~/.allbert/memory/index/`
- `~/.allbert/memory/index/semantic/`
- `~/.allbert/memory/.trash/`
- `~/.allbert/memory/migrations/`

Workflow summary:

- approved durable memory lives under `notes/`
- candidate learnings land in `staging/`
- `memory promote` moves staged entries into `notes/` and schedules re-index
- `memory reject` archives staged entries under `staging/.rejected/`
- `memory forget` moves approved durable notes into `.trash/` with explicit confirmation
- `memory search --tier episode` searches bounded working history from session journals
- `memory search --tier fact` searches approved durable fact metadata
- `memory verify` performs the same checksum-based reconciliation check you can script against when the daemon is offline

Use the assistant naturally, but remember the architecture rule: durable recall comes from curated memory files, not hidden long-lived chat logs. Episode recall is explicitly labelled working history, and facts become approved only after promotion.

If you are upgrading to v0.12, see [v0.12-upgrade-2026-04-25.md](notes/v0.12-upgrade-2026-04-25.md), [v0.11-upgrade-2026-04-24.md](notes/v0.11-upgrade-2026-04-24.md), and [v0.10-upgrade-2026-04-24.md](notes/v0.10-upgrade-2026-04-24.md). If you are coming from v0.8 or earlier, also review [v0.9-upgrade-2026-04-24.md](notes/v0.9-upgrade-2026-04-24.md) and [v0.8-upgrade-2026-04-23.md](notes/v0.8-upgrade-2026-04-23.md).

## Self-improvement and scripting

Self-improvement is source-checkout-bound and review-first. Configure a source checkout only if you want `rust-rebuild`:

```bash
cargo run -p allbert-cli -- self-improvement config show
cargo run -p allbert-cli -- self-improvement config set --source-checkout /path/to/allbert-assist
```

Rebuild worktrees live under `~/.allbert/worktrees/` by default. Inspect or reclaim stale worktrees:

```bash
cargo run -p allbert-cli -- self-improvement gc --dry-run
cargo run -p allbert-cli -- self-improvement gc
```

Patch proposals route through the normal inbox as `patch-approval` items. `inbox accept` records review only; it does not apply the diff. Use the dedicated commands after review:

```bash
cargo run -p allbert-cli -- self-improvement diff <approval-id>
cargo run -p allbert-cli -- self-improvement install <approval-id>
```

`self-improvement install` applies the accepted patch to the configured source checkout and prints the operator-owned `cargo install --path crates/allbert-cli` plus daemon restart hint. The daemon never swaps its own binary.

Lua scripting is disabled by default and requires two gates:

```toml
[scripting]
engine = "lua"

[security]
exec_allow = ["bash", "python", "lua"]
```

Lua is an embedded JSON-in/JSON-out transform surface. It has no host tool bridge in v0.12 and runs with a strict standard-library allowlist plus execution, memory, and output caps. See [scripting.md](operator/scripting.md) for details.

## Personality digest

`SOUL.md` remains the seeded, operator-owned persona and boundary file. v0.11 adds optional `PERSONALITY.md` as a reviewed learned overlay. It is absent by default, loaded only when present, and lower-authority than current user instruction, `SOUL.md`, profile files, policy, and tool/security rules.

Preview the digest corpus without provider calls or file writes:

```bash
cargo run -p allbert-cli -- learning digest --preview
```

Run a draft once after enabling `[learning]` and `[learning.personality_digest]`:

```bash
cargo run -p allbert-cli -- learning digest --run
```

Install accepted output atomically to `PERSONALITY.md`:

```bash
cargo run -p allbert-cli -- learning digest --run --accept
```

Enable or disable the bundled schedule template:

```bash
cargo run -p allbert-cli -- jobs template enable personality-digest
cargo run -p allbert-cli -- jobs template disable personality-digest
```

Draft artifacts live under `~/.allbert/learning/personality-digest/runs/<run_id>/`. See [personality-digest.md](operator/personality-digest.md) for the authority model and acceptance flow.

## Trace, logs, and cost files

Daemon logs:

- `~/.allbert/logs/daemon.log`
- `~/.allbert/logs/daemon.debug.log`

Cost logs:

- written automatically to `~/.allbert/costs.jsonl`
- view the current session, today's totals, and cap state with `/cost`

Job history:

- `~/.allbert/jobs/runs/<YYYY-MM-DD>.jsonl`
- `~/.allbert/jobs/failures/<YYYY-MM-DD>.jsonl`

## Troubleshooting

Missing API key:

- Ollama does not require an API key; `/status` should show `not required`
- hosted providers show which env var is missing
- export it and restart the CLI or switch back to Ollama with `/model ollama gemma4`

Ollama turn fails:

- confirm Ollama is installed and running
- run `ollama run gemma4` once to pull/start the default model
- if Ollama listens somewhere else, rerun `/setup` or set `base_url` under `[model]`

`/status` shows no trusted roots:

- rerun `/setup`
- or edit `~/.allbert/config.toml` manually and reload the session

File access denied:

- confirm the target path is under one of your trusted roots
- remember that Allbert canonicalizes paths and rejects escape attempts

Daemon will not auto-start:

- run `cargo run -p allbert-cli -- daemon start`
- if that fails, confirm the `allbert-daemon` binary exists in the target directory next to `allbert-cli`
- check for stale socket or permission drift under `~/.allbert/run/`

Provider errors:

- for hosted providers, confirm the correct env var is set for the active provider
- for Ollama, confirm the local base URL is reachable and the model has been pulled
- check network connectivity for hosted providers
- switch providers with `/model` if needed

Job failed unexpectedly:

- run `allbert-cli jobs status <name>`
- inspect `~/.allbert/jobs/failures/<YYYY-MM-DD>.jsonl`
- check `daemon.debug.log` if trace is enabled

Setup feels incomplete:

- rerun `/setup`
- check whether `~/.allbert/BOOTSTRAP.md` is still present

Curated memory seems wrong or stale:

- run `cargo run -p allbert-cli -- memory status`
- run `cargo run -p allbert-cli -- memory stats`
- run `cargo run -p allbert-cli -- memory verify`
- run `cargo run -p allbert-cli -- memory rebuild-index --force`
- check whether a staged entry is still waiting in `memory staged list`
- if you upgraded from v0.10 or earlier, check the upgrade notes and expect a derived index rebuild on first launch

TUI unavailable:

- rerun with `cargo run -p allbert-cli -- repl --classic`
- check whether your terminal supports raw mode and alternate screen
- persist classic fallback with `cargo run -p allbert-cli -- repl --classic --save`

## Release posture

v0.12 is a shipped technical-user release:

- source-based
- terminal-first
- daemon-backed but still local-user-only
- fresh-profile TUI with classic REPL fallback for upgrades
- daemon-owned telemetry through TUI, REPL, and CLI
- explicit workspace trust
- guided bootstrap and daemon/jobs setup
- restart-durable sessions with `sessions resume`
- identity-routed cross-surface continuity with `identity`, `sessions`, and `inbox`
- daily cost-cap enforcement with one-turn REPL override
- operator-visible memory verification through `memory status` and `memory verify`
- configurable always-eligible memory routing
- explicit episode and fact memory search tiers
- optional semantic retrieval seam, disabled by default
- review-first personality digest seam and optional `PERSONALITY.md` learned overlay
- source-checkout-bound self-improvement worktrees with `patch-approval` review
- explicit `self-improvement diff|install|gc` operator commands
- first-party `skill-author` natural-language skill drafting through quarantine
- skill provenance surfaced in previews and `skills list`
- opt-in embedded Lua scripting with two-gate enablement and sandbox caps
- first-class agents and intent routing with operator-visible status
- strict AgentSkills-format skill install, inspection, and execution
- channel administration through `daemon channels ...`
- approval inspection and resolution through `approvals list|show` and `inbox list|show|accept|reject`
- profile export/import plus documented sync posture
- `HEARTBEAT.md` inspection, validation, and proactive cadence controls
- Telegram async approvals and Telegram photo input for vision-capable models
- Anthropic, OpenRouter, OpenAI, Gemini, and local Ollama provider support
- fresh-profile Ollama/Gemma4 defaults with no hosted API key required

Known limitations remain explicit:

- no remote control plane
- no boot-time OS service install yet
- incomplete tool invocations still rewind to the last completed turn boundary after daemon restart
- unsolicited heartbeat delivery is still Telegram-only
- daily cost caps are still per-device
- Telegram multimodal support is photos-in only; voice notes, audio, and image output are deferred
- the daemon is lightweight and in-process, not a heavy isolated supervisor
- sub-agent depth is budget-governed rather than fixed by nesting count
- semantic retrieval is fake-provider-only
- personality digest output is deterministic and review-first; model-authored digest prose and adapter training are future work
- `rust-rebuild` requires a local source checkout and never swaps the running binary automatically
- Lua scripting is JSON-in/JSON-out only; it has no host tool bridge in v0.12
