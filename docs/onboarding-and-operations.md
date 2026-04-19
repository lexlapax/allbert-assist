# Allbert v0.2 Onboarding and Operations

This guide is the operator reference for the source-based v0.2 release.

## Quickstart

1. Export at least one provider API key.
2. Run `cargo run -p allbert-cli --`.
3. Complete the guided setup flow.
4. Confirm daemon/session state with `/status`.
5. Use `allbert-cli daemon status` and `allbert-cli jobs list` as needed.

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

- `config.toml` is updated with `setup.version = 2`
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

This is intentional. v0.2 still prefers explicit workspace trust over permissive defaults.

## Example config

`~/.allbert/config.toml` is written automatically. A typical v0.2 file looks like:

```toml
trace = false

[model]
provider = "anthropic"
model_id = "claude-sonnet-4-5"
api_key_env = "ANTHROPIC_API_KEY"
max_tokens = 4096

[setup]
version = 2

[daemon]
log_retention_days = 7
auto_spawn = true

[jobs]
enabled = false
max_concurrent_runs = 1
default_timeout_s = 600
default_timezone = "America/Los_Angeles"

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

- `/help`
  Shows the command list.
- `/status`
  Shows provider, model, API-key env presence, setup version, bootstrap pending state, trusted roots, daemon auto-spawn, jobs enablement, jobs timezone, skill count, and trace mode.
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

Scheduled job failures are surfaced live to attached REPL clients as one-line notices, and they also remain recorded durably under `~/.allbert/jobs/failures/`.

## Daemon lifecycle

The primary operator surface is `allbert-cli`.

Daemon commands:

- `cargo run -p allbert-cli -- daemon status`
- `cargo run -p allbert-cli -- daemon start`
- `cargo run -p allbert-cli -- daemon stop`
- `cargo run -p allbert-cli -- daemon restart`
- `cargo run -p allbert-cli -- daemon logs [--debug] [--follow] [--lines N]`

Notes:

- `daemon stop` is explicit and bounded graceful. It stops new work, interrupts remaining scheduled runs if needed, and records interrupted runs as non-success outcomes.
- Ctrl-C in the REPL detaches the client but does not stop the daemon.
- `daemon logs --debug --follow` is the quickest way to watch daemon-side diagnostics live.

## Jobs workflow

Jobs are daemon-owned and non-interactive by default.

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

## Bundled maintenance jobs

v0.2 seeds these disabled templates:

- `daily-brief`
- `weekly-review`
- `memory-compile`
- `trace-triage`
- `system-health-check`

The setup wizard can enable selected templates for you. If you skip them there, they stay available under `~/.allbert/jobs/templates/` until you copy or upsert them yourself.

## Skills and memory

Skills live under `~/.allbert/skills/`.

Memory is durable and file-based:

- `~/.allbert/memory/MEMORY.md`
- `~/.allbert/memory/daily/`
- `~/.allbert/memory/topics/`
- `~/.allbert/memory/people/`
- `~/.allbert/memory/projects/`
- `~/.allbert/memory/decisions/`

Use the assistant naturally, but remember the architecture rule: durable recall comes from memory files, not hidden long-lived chat logs.

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

## Release posture

v0.2 is a technical-user release:

- source-based
- terminal-first
- daemon-backed but still local-user-only
- explicit workspace trust
- guided bootstrap and daemon/jobs setup

Known limitations remain explicit:

- no remote control plane
- no boot-time OS service install yet
- in-memory interactive sessions are not restart-durable
- the daemon is lightweight and in-process, not a heavy isolated supervisor
