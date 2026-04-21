# Allbert v0.5 Onboarding and Operations

This guide is the operator reference for the source-based v0.5 release.

## Quickstart

1. Export at least one provider API key.
2. Run `cargo run -p allbert-cli --`.
3. Complete the guided setup flow.
4. Confirm daemon/session state with `/status`.
5. Use `allbert-cli daemon status`, `allbert-cli jobs list`, and `allbert-cli memory status` as needed.
6. Inspect the current agent catalog with `allbert-cli agents list` and the shipped curator flow with `allbert-cli skills show memory-curator`.

## Guided setup

On first run, Allbert creates `~/.allbert/` and asks for:

- your preferred name
- your timezone, with a guessed default when available
- how Allbert should usually work with you, with a practical default
- your current priorities, with a safe fallback if you have none to record yet
- optional assistant identity edits for Allbert itself
- trusted filesystem roots, with the current project directory offered as the default first root
- whether the CLI should auto-start the daemon when needed
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

This is intentional. v0.5 still prefers explicit workspace trust over permissive defaults.

## Example config

`~/.allbert/config.toml` is written automatically. A typical v0.5 file looks like:

```toml
trace = false

[model]
provider = "anthropic"
model_id = "claude-sonnet-4-5"
api_key_env = "ANTHROPIC_API_KEY"
max_tokens = 4096

[setup]
version = 3

[daemon]
log_retention_days = 7
auto_spawn = true

[jobs]
enabled = false
max_concurrent_runs = 1
default_timeout_s = 600
default_timezone = "America/Los_Angeles"

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
surface_staged_on_turn_end = true

[security]
fs_roots = ["/absolute/path/to/workspace"]
auto_confirm = false

[security.web]
allow_hosts = []
deny_hosts = []
timeout_s = 15

[limits]
max_turns = 8
max_tool_calls_per_turn = 16
max_tool_output_bytes_per_call = 8192
max_tool_output_bytes_total = 65536
max_bootstrap_file_bytes = 2048
max_prompt_bootstrap_bytes = 6144
max_prompt_memory_bytes = 4096
max_skill_args_bytes = 2048
```

The CLI may override some of this for the current REPL session:

- `--trace` enables daemon debug logging for the running daemon
- `--yes` enables session-only auto-confirm for the attached REPL session

## REPL usage

Useful REPL commands:

- `/h`
  Alias for `/help`.
- `/help`
  Shows the command list.
- `/s`
  Alias for `/status`.
- `/status`
  Shows provider, model, root agent, last active agent stack, last resolved intent, API-key env presence, setup version, bootstrap pending state, trusted roots, daemon auto-spawn, jobs enablement, jobs timezone, skill count, and trace mode.
- `/setup`
  Reruns guided setup. This updates config/bootstrap state and reloads daemon defaults plus job definitions for the current daemon session.
- `/model`
  Shows the active session model configuration.
- `/model <anthropic|openrouter> <model_id> [api_key_env]`
  Switches provider/model for the attached session only.
- `/cost`
  Shows session cost and today's recorded total from `~/.allbert/costs.jsonl`.
- `/exit`
  Leaves the REPL without stopping the daemon.

Unknown slash commands are rejected locally with a short hint to use `/help`; they are not forwarded to the model.

For curated-memory review, the most useful operator commands are:

- `cargo run -p allbert-cli -- memory status`
- `cargo run -p allbert-cli -- memory search "postgres"`
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

## Daemon lifecycle

The primary operator surface is `allbert-cli`.

Daemon commands:

- `cargo run -p allbert-cli -- daemon status`
- `cargo run -p allbert-cli -- daemon start`
- `cargo run -p allbert-cli -- daemon stop`
- `cargo run -p allbert-cli -- daemon restart`
- `cargo run -p allbert-cli -- daemon logs [--debug] [--follow] [--lines N]`

Agent commands:

- `cargo run -p allbert-cli -- agents list`

`allbert-cli agents list` prints the same catalog the kernel writes to `~/.allbert/AGENTS.md`.

Notes:

- `daemon stop` is explicit and bounded graceful. It stops new work, interrupts remaining scheduled runs if needed, and records interrupted runs as non-success outcomes.
- Ctrl-C in the REPL detaches the client but does not stop the daemon.
- `daemon logs --debug --follow` is the quickest way to watch daemon-side diagnostics live.

## Jobs workflow

Jobs are daemon-owned and non-interactive by default.

Job lifecycle management is authoritative through the CLI surfaces below, and daemon-backed prompt job tools now make conversational scheduling a first-class path too. Durable schedule mutation goes through an explicit preview-and-confirm step in interactive sessions. The CLI remains the clearest operator surface, but it is no longer the only trustworthy way to manage recurring jobs.

Canonical commands:

- `cargo run -p allbert-cli -- jobs list`
- `cargo run -p allbert-cli -- jobs status <name>`
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

Common schedule forms the assistant should compile naturally in v0.5:

- `@daily at HH:MM`
- `@weekly on monday at HH:MM`
- `every 2h`
- `once at 2026-04-20T16:00:00Z`

When you create, update, pause, resume, or remove a job from normal conversation, Allbert shows a durable-change preview and waits for explicit confirmation before persisting it.

## Bundled maintenance jobs

v0.5 still seeds these disabled templates:

- `daily-brief`
- `weekly-review`
- `memory-compile`
- `trace-triage`
- `system-health-check`

The setup wizard can enable selected templates for you. If you skip them there, they stay available under `~/.allbert/jobs/templates/` until you copy or upsert them yourself.

## Skills and memory

The canonical installed skill root in v0.5 is `~/.allbert/skills/installed/`.

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

v0.5 expects strict AgentSkills-format skill trees at install time. `skills validate` is the preflight tool; Allbert does not ship a runtime migration helper for older relaxed skill layouts.

In v0.5, skills can also preview:

- `intents:` metadata to hint the intent router
- `agents:` metadata to contribute namespaced sub-agents

The active agent roster is written to `~/.allbert/AGENTS.md` and included in the bootstrap prompt bundle.

Fresh profiles also seed the shipped `memory-curator` skill. It is the first-party review surface around the kernel-owned memory tools:

- `cargo run -p allbert-cli -- skills list`
- `cargo run -p allbert-cli -- skills show memory-curator`

Curated memory is durable and markdown-grounded:

- `~/.allbert/memory/MEMORY.md`
- `~/.allbert/memory/daily/`
- `~/.allbert/memory/notes/`
- `~/.allbert/memory/staging/`
- `~/.allbert/memory/manifest.json`
- `~/.allbert/memory/index/`
- `~/.allbert/memory/.trash/`
- `~/.allbert/memory/migrations/`

Workflow summary:

- approved durable memory lives under `notes/`
- candidate learnings land in `staging/`
- `memory promote` moves staged entries into `notes/` and schedules re-index
- `memory reject` archives staged entries under `staging/.rejected/`
- `memory forget` moves approved durable notes into `.trash/` with explicit confirmation

Use the assistant naturally, but remember the architecture rule: durable recall comes from curated memory files, not hidden long-lived chat logs.

If you are upgrading from v0.4, see [v0.5-upgrade-2026-04-20.md](notes/v0.5-upgrade-2026-04-20.md) for the bucket import and validation checklist.

## Trace, logs, and cost files

Daemon logs:

- `~/.allbert/logs/daemon.log`
- `~/.allbert/logs/daemon.debug.log`

Cost logs:

- written automatically to `~/.allbert/costs.jsonl`
- view the current session and today's totals with `/cost`

Job history:

- `~/.allbert/jobs/runs/<YYYY-MM-DD>.jsonl`
- `~/.allbert/jobs/failures/<YYYY-MM-DD>.jsonl`

## Troubleshooting

Missing API key:

- startup warning tells you which env var is missing
- export it and restart the CLI

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

- confirm the correct env var is set for the active provider
- check network connectivity
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
- run `cargo run -p allbert-cli -- memory rebuild-index --force`
- check whether a staged entry is still waiting in `memory staged list`
- if you upgraded from v0.4, confirm the import report under `~/.allbert/memory/migrations/`

## Release posture

v0.5 is a shipped technical-user release:

- source-based
- terminal-first
- daemon-backed but still local-user-only
- explicit workspace trust
- guided bootstrap and daemon/jobs setup
- first-class agents and intent routing with operator-visible status
- strict AgentSkills-format skill install, inspection, and execution

Known limitations remain explicit:

- no remote control plane
- no boot-time OS service install yet
- in-memory interactive sessions are not restart-durable
- the daemon is lightweight and in-process, not a heavy isolated supervisor
- sub-agent delegation remains bounded to one nested level
