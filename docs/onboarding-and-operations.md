# Allbert v0.1 Onboarding and Operations

This guide is the operator reference for the source-based v0.1 release.

## Quickstart

1. Export at least one provider API key.
2. Run `cargo run -p allbert-cli --`.
3. Complete the guided setup flow.
4. Confirm your status with `/status`.
5. Add example skills if you want them.

## Guided setup

On first run, Allbert creates `~/.allbert/` and asks for:

- your preferred name
- your timezone, with a guessed default when available
- how Allbert should usually work with you, with a practical default
- your current priorities, with a safe fallback if you have none to record yet
- optional assistant identity edits for Allbert itself
- trusted filesystem roots, with the current project directory offered as the default first root

Type `/cancel` at any setup prompt to abort setup cleanly.

If setup completes:

- `config.toml` is updated with `setup.version = 1`
- `USER.md` is filled with the confirmed profile values
- `IDENTITY.md` is updated only if you chose to customize assistant identity
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

This is intentional. v0.1 prefers explicit workspace trust over permissive defaults.

## Example config

`~/.allbert/config.toml` is written automatically. A typical file looks like:

```toml
trace = false

[model]
provider = "anthropic"
model_id = "claude-sonnet-4-5"
api_key_env = "ANTHROPIC_API_KEY"
max_tokens = 4096

[setup]
version = 1

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

The CLI may override some of this in memory for the current run:

- `--trace` enables daemon debug logging for the running daemon at `~/.allbert/logs/daemon.debug.log`
- `--yes` enables session-only auto-confirm for the attached daemon-backed session

## Slash commands

- `/help`
  Shows the command list.
- `/status`
  Shows provider, model, API-key env presence, setup version, bootstrap pending state, trusted roots, skill count, and trace mode.
- `/setup`
  Reruns guided setup. This updates config/bootstrap state and refreshes trusted roots for the current session.
- `/model`
  Shows the active model configuration.
- `/model <anthropic|openrouter> <model_id> [api_key_env]`
  Switches provider/model during the current session.
- `/cost`
  Shows session cost and today's recorded total from `~/.allbert/costs.jsonl`.
- `/exit`
  Leaves the REPL.

## Skills workflow

The repo includes `examples/skills/note-taker/SKILL.md`, but example skills are not auto-installed into `~/.allbert/skills/`.

Install the example manually:

```bash
mkdir -p ~/.allbert/skills
cp -r examples/skills/note-taker ~/.allbert/skills/
```

Then ask Allbert to list or invoke skills in the REPL.

Skill manifests are always visible to the model. Full skill bodies are only injected after explicit activation.

## Memory workflow

Memory is durable and file-based:

- `~/.allbert/memory/MEMORY.md`
- `~/.allbert/memory/daily/`
- `~/.allbert/memory/topics/`
- `~/.allbert/memory/people/`
- `~/.allbert/memory/projects/`
- `~/.allbert/memory/decisions/`

Use the assistant naturally, but remember the architecture rule: durable recall comes from memory files, not hidden long-lived chat logs.

## Trace and cost files

Trace logs:

- enable with `cargo run -p allbert-cli -- --trace`
- written to `~/.allbert/logs/daemon.debug.log` for the running daemon

Cost logs:

- written automatically to `~/.allbert/costs.jsonl`
- view summary with `/cost`

## Troubleshooting

Missing API key:

- startup warning tells you which env var is missing
- export it and restart the CLI

`/status` shows no trusted roots:

- rerun `/setup`
- or edit `~/.allbert/config.toml` manually and restart

File access denied:

- confirm the target path is under one of your trusted roots
- remember that Allbert canonicalizes paths and rejects escape attempts

Provider errors:

- confirm the correct env var is set for the active provider
- check network connectivity
- switch providers with `/model` if needed

Setup feels incomplete:

- rerun `/setup`
- check whether `~/.allbert/BOOTSTRAP.md` is still present

Trace logs missing:

- start the CLI with `--trace`
- check `~/.allbert/logs/daemon.debug.log`
- there is not yet a dedicated `allbert trace on|off` command in the CLI

## Release posture

v0.1 is a technical-user release:

- source-based
- terminal-first
- explicit workspace trust
- guided bootstrap setup

Packaged installers and broader frontend surfaces are intentionally deferred.
