# Allbert v0.14.2 Operator Playbook

This is the current source-based operator playbook for Allbert v0.14.2. It is the start-here guide for running, checking, and release-validating the shipped operator surface from first setup through the latest v0.14.2 architecture gates.

Focused guides go deeper on individual areas:

- [TUI](operator/tui.md)
- [Operator feature test runbook](operator/feature-test-runbook.md)
- [Telemetry and activity](operator/telemetry.md)
- [Tracing and replay](operator/tracing.md)
- [Adaptive memory](operator/adaptive-memory.md)
- [Cost caps](operator/cost-caps.md)
- [Continuity and sync](operator/continuity.md)
- [Heartbeat](operator/heartbeat.md)
- [Personality digest](operator/personality-digest.md)
- [Personalization adapters](operator/personalization.md)
- [Self-diagnosis and local utilities](operator/self-diagnosis-and-utilities.md)
- [Self-improvement](operator/self-improvement.md)
- [Skill authoring](operator/skill-authoring.md)
- [Scripting](operator/scripting.md)
- [Telegram](operator/telegram.md)

## Quickstart

Use a temporary profile for safe smoke checks:

```bash
tmpdir=$(mktemp -d /tmp/allbert-operator-smoke.XXXXXX)
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- doctor
```

For a real profile:

1. Install Ollama separately and run `ollama run gemma4` if you want the fresh-profile local default to work on the first live turn.
2. Export hosted-provider keys only if you plan to use Anthropic, OpenRouter, OpenAI, or Gemini.
3. Start Allbert with `cargo run -p allbert-cli --`.
4. Complete guided setup.
5. Confirm state with `/status`, `/telemetry`, `/activity`, `allbert-cli daemon status`, and `allbert-cli doctor`.

Live-provider, Telegram, and real adapter-trainer checks are optional operator-credentialed follow-ups. They are not part of the default provider-free contributor gate.

## Guided Setup

On first run, Allbert creates `~/.allbert/`, seeds bootstrap files, writes `config.toml`, and opens guided setup before the daemon-backed interactive surface starts.

Setup asks for:

- preferred name and timezone
- collaboration style and current priorities
- optional assistant identity refinements
- default provider and model, fresh-profile defaulting to local `ollama` / `gemma4`
- hosted API-key env var or local Ollama base URL
- trusted filesystem roots
- daemon auto-spawn preference
- TUI or classic REPL default
- daily hosted-provider cost cap
- recurring job defaults and bundled job templates
- trace/replay defaults
- adapter-training posture, allowed backend, compute cap, and trace-corpus choice
- local-utility discovery preference

Trusted roots matter. File tools are disabled outside directories you explicitly trust. Setup may suggest the current working directory, but it does not silently trust it.

If setup is interrupted, resume with:

```bash
cargo run -p allbert-cli -- setup --resume
```

## Common Settings

Prefer the typed settings surface over hand-editing `config.toml`:

```bash
cargo run -p allbert-cli -- settings list
cargo run -p allbert-cli -- settings show model
cargo run -p allbert-cli -- settings show security.exec_allow
cargo run -p allbert-cli -- settings show learning.adapter_training
cargo run -p allbert-cli -- settings show local_utilities
cargo run -p allbert-cli -- settings show self_diagnosis
```

Common direct config shapes:

```toml
[model]
provider = "ollama"
model_id = "gemma4"
base_url = "http://127.0.0.1:11434"

[limits]
daily_usd_cap = 5.0

[security]
fs_roots = ["/absolute/path/to/workspace"]
exec_allow = ["bash", "python"]

[scripting]
engine = "disabled"
```

Hosted providers use `api_key_env` in the same `[model]` table. Supported provider labels are `anthropic`, `openrouter`, `openai`, `gemini`, and `ollama`.

## Artifacts You Should Know

- `~/.allbert/config.toml` and `~/.allbert/config.toml.last-good`
- `~/.allbert/SOUL.md`, `USER.md`, `IDENTITY.md`, `TOOLS.md`, `AGENTS.md`, and `HEARTBEAT.md`
- `~/.allbert/PERSONALITY.md`, when a digest is accepted
- `~/.allbert/run/daemon.sock`
- `~/.allbert/logs/daemon.log` and `daemon.debug.log`
- `~/.allbert/jobs/`
- `~/.allbert/memory/`
- `~/.allbert/sessions/<session-id>/trace.jsonl`
- `~/.allbert/sessions/<session-id>/artifacts/`
- `~/.allbert/skills/installed/` and `skills/incoming/`
- `~/.allbert/worktrees/`
- `~/.allbert/utilities/enabled.toml`
- `~/.allbert/costs.jsonl`

## Feature Test Playbook

The commands below are the practical operator checklist for the shipped v0.14.2 surface. Prefer a temp `ALLBERT_HOME` for smoke checks unless you intentionally want to inspect your real profile.

### v0.1 - CLI, Onboarding, Kernel, Skills, Memory, Policy

Use:

```bash
cargo run -p allbert-cli -- setup
cargo run -p allbert-cli -- repl --classic
cargo run -p allbert-cli -- doctor
cargo run -p allbert-cli -- skills list
cargo run -p allbert-cli -- memory status
```

Test:

- Confirm first-run files exist under `ALLBERT_HOME`.
- Confirm `doctor`, `skills list`, and `memory status` work without a live provider.
- Confirm file tools reject paths outside trusted roots.

### v0.2 - Daemon, Jobs, Sessions

Use:

```bash
cargo run -p allbert-cli -- daemon start
cargo run -p allbert-cli -- daemon status
cargo run -p allbert-cli -- jobs list
cargo run -p allbert-cli -- sessions list
cargo run -p allbert-cli -- daemon stop
```

Test:

- Start and stop the daemon cleanly.
- Run a built-in job only when jobs are enabled for the temp profile.
- Inspect `~/.allbert/jobs/runs/` and `~/.allbert/jobs/failures/` when diagnosing job behavior.

### v0.3 - Agents And Intent Routing

Use:

```bash
cargo run -p allbert-cli -- agents list
```

In REPL/TUI:

```text
/agents
/status
```

Test:

- Confirm `~/.allbert/AGENTS.md` is generated.
- Confirm `agents list` shows the root agent and any skill-contributed agents.
- Ask ordinary scheduling, memory, and chat requests and check `/status` for the last resolved intent.

### v0.4 - AgentSkills

Use:

```bash
cargo run -p allbert-cli -- skills init demo-skill
cargo run -p allbert-cli -- skills validate <path-to-skill>
cargo run -p allbert-cli -- skills install <path-or-git-url>
cargo run -p allbert-cli -- skills show <name>
cargo run -p allbert-cli -- skills disable <name>
cargo run -p allbert-cli -- skills enable <name>
```

Test:

- Validate before install.
- Confirm install/update previews show provenance, scripts, hashes, and `allowed-tools`.
- Confirm scripts still require the central exec policy.

### v0.5 - Curated Memory

Use:

```bash
cargo run -p allbert-cli -- memory stats
cargo run -p allbert-cli -- memory verify
cargo run -p allbert-cli -- memory search "postgres"
cargo run -p allbert-cli -- memory staged list
cargo run -p allbert-cli -- memory promote <id> --confirm
cargo run -p allbert-cli -- memory reject <id> --reason "not durable"
cargo run -p allbert-cli -- memory forget <path-or-query> --confirm
cargo run -p allbert-cli -- memory restore <id-or-path>
cargo run -p allbert-cli -- memory rebuild-index --force
```

Test:

- Confirm durable notes live under `memory/notes/`.
- Confirm candidate learnings stay in `memory/staging/` until review.
- Confirm `memory verify` is clean after promotion, rejection, restore, or index rebuild.

### v0.6 - Hardening, Cost Caps, Recovery

Use:

```text
/cost
/cost --override "operator-approved one turn"
```

```bash
cargo run -p allbert-cli -- memory recovery-gc
cargo run -p allbert-cli -- config restore-last-good
```

Test:

- Confirm hosted-provider cost caps are per local profile.
- Confirm one-turn cost override requires a reason and is not durable.
- Confirm recovery commands preserve review boundaries.

### v0.7 - Channels, Telegram Pilot, Explicit Web Learning

Use:

```bash
cargo run -p allbert-cli -- daemon channels list
cargo run -p allbert-cli -- daemon channels add telegram
cargo run -p allbert-cli -- daemon channels status telegram
```

Test:

- Provider-free smoke: enable Telegram config and inspect status without sending live messages.
- Live Telegram requires a bot token and allowlisted chat id.
- Explicit web learning still requires `record_as`; search/fetch does not silently write durable memory.

### v0.8 - Continuity, Identity, Inbox, Profile Export

Use:

```bash
cargo run -p allbert-cli -- identity show
cargo run -p allbert-cli -- inbox list
cargo run -p allbert-cli -- heartbeat show
cargo run -p allbert-cli -- profile export /tmp/allbert-profile.tgz
cargo run -p allbert-cli -- profile import /tmp/allbert-profile.tgz --overlay
```

Test:

- Export from one temp profile and import into another.
- Confirm secrets, local utility enablement, run sockets, and host-specific caches are excluded.
- Confirm approvals can be resolved from CLI, TUI, REPL, or Telegram when identity matches.

### v0.9 - Contributor And Codex-Web Readiness

Use the provider-free contributor gate:

```bash
cargo fmt --check
env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTC_WRAPPER cargo test -q
env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
```

Test:

- Use temp homes for smokes.
- Do not require secrets, live providers, Telegram, or long-lived daemons for the default green path.

### v0.10 - Providers

Use:

```text
/model
/model ollama gemma4
/model openai <model-id> OPENAI_API_KEY
```

```bash
cargo run -p allbert-cli -- settings show model
```

Test:

- Provider-free: inspect config and help.
- Local live: run Ollama and pull the configured model.
- Hosted live: export the provider key and verify `/status` reports the env var is visible.

### v0.11 - TUI, Telemetry, Adaptive Memory, Personality Digest

Use:

```bash
cargo run -p allbert-cli -- repl --tui
cargo run -p allbert-cli -- telemetry --json
cargo run -p allbert-cli -- activity --json
cargo run -p allbert-cli -- memory routing show
cargo run -p allbert-cli -- memory search "debugging decision" --tier episode
cargo run -p allbert-cli -- memory search "project storage" --tier fact
cargo run -p allbert-cli -- learning digest --preview
```

Test:

- Confirm TUI falls back to classic mode if terminal setup fails.
- Confirm telemetry/activity are daemon-owned live state.
- Confirm digest preview is provider-free and does not write `PERSONALITY.md`.

### v0.12 - Self-Improvement, Skill Authoring, Lua Scripting

Use:

```bash
cargo run -p allbert-cli -- self-improvement config show
cargo run -p allbert-cli -- self-improvement config set --source-checkout /path/to/allbert-assist
cargo run -p allbert-cli -- self-improvement gc --dry-run
cargo run -p allbert-cli -- self-improvement diff <approval-id>
cargo run -p allbert-cli -- self-improvement install <approval-id>
cargo run -p allbert-cli -- skills show skill-author
```

Test:

- Confirm self-improvement requires a source checkout and sibling worktree.
- Confirm patch acceptance records review only; install is a separate command.
- Confirm Lua requires both `[scripting].engine = "lua"` and exec policy.

### v0.12.1 - Operator UX

Use:

```bash
cargo run -p allbert-cli -- settings list
cargo run -p allbert-cli -- settings show repl.tui
cargo run -p allbert-cli -- settings explain repl.tui.spinner_style
cargo run -p allbert-cli -- settings reset repl.tui.spinner_style
cargo run -p allbert-cli -- activity
```

Test:

- Confirm unsupported settings are rejected without rewriting unrelated TOML.
- Confirm TUI, CLI, and REPL render the same activity and inbox state.

### v0.12.2 - Tracing And Replay

Use:

```bash
cargo run -p allbert-cli -- trace list
cargo run -p allbert-cli -- trace show
cargo run -p allbert-cli -- trace show-span <span-id>
cargo run -p allbert-cli -- trace tail
cargo run -p allbert-cli -- trace export <session-id>
cargo run -p allbert-cli -- trace gc
```

Test:

- Run a turn, then confirm spans are visible.
- Export file-based OTLP JSON.
- Confirm prompts, responses, provider payloads, and tool content follow trace redaction settings.

### v0.13 - Local Personalization Adapters

Use:

```bash
cargo run -p allbert-cli -- adapters status
cargo run -p allbert-cli -- adapters training preview
cargo run -p allbert-cli -- adapters training start
cargo run -p allbert-cli -- inbox list --kind adapter-approval
cargo run -p allbert-cli -- adapters activate <adapter-id>
cargo run -p allbert-cli -- adapters deactivate
```

Test:

- Safe smoke: run `adapters training preview` with training disabled and confirm the error/preview is clear.
- Contributor fake smoke: use an explicit temp profile with backend `fake`, allowed backend `fake`, and `fake-adapter-trainer` in `security.exec_allow`.
- Real training: enable only after selecting a local trainer backend, allowlisting it, and setting a compute cap.
- Confirm accepting an adapter approval installs but does not automatically activate it.

### v0.14 - Self-Diagnosis, Local Utilities, unix_pipe

Use:

```bash
cargo run -p allbert-cli -- diagnose run
cargo run -p allbert-cli -- diagnose list
cargo run -p allbert-cli -- diagnose show <diagnosis-id>
cargo run -p allbert-cli -- utilities discover
cargo run -p allbert-cli -- utilities enable rg
cargo run -p allbert-cli -- utilities doctor
```

Test:

- Confirm diagnosis writes reports under `sessions/<session-id>/artifacts/diagnostics/`.
- Confirm remediation requires `self_diagnosis.allow_remediation = true` plus `--remediate <kind> --reason <text>`.
- Confirm `unix_pipe` can use only enabled utilities with `ok` status and exec-policy approval.

### v0.14.1 - Reconciliation Checks

Use:

```bash
cargo run -p allbert-cli -- doctor
cargo run -p allbert-cli -- adapters training preview
cargo run -p allbert-cli -- diagnose run --remediate code --reason "operator requested candidate"
```

Test:

- Confirm direct tool-call repair still respects the active tool catalog, active skill `allowed-tools`, and `security.exec_allow`.
- Confirm disabled or missing adapter training fails clearly instead of silently using a fake trainer.
- Confirm remediation candidates record fallback/provider provenance and route through review surfaces.

### v0.14.2 - Core/Services Split And Daemon Reliability

Use:

```bash
tools/check_kernel_size.sh --enforce
tools/check_kernel_crate_graph.sh --enforce
tools/check_kernel_import_migration.sh --enforce
tools/check_kernel_dependency_compactness.sh --enforce
```

Test:

- Confirm no workspace Rust code imports the retired `allbert_kernel` crate.
- Confirm daemon integration tests pass under default parallel execution without the old local socket `Operation not permitted` workaround.
- Confirm there is no operator-visible command, protocol, or profile migration for the core/services split.

## Telegram

Telegram is optional and credentialed.

Provider-free local smoke:

```bash
tmpdir=$(mktemp -d /tmp/allbert-telegram-smoke.XXXXXX)
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon channels add telegram
ALLBERT_HOME="$tmpdir" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- daemon channels status telegram
```

Live setup:

1. Put the bot token in `~/.allbert/secrets/telegram/bot_token`.
2. Put one allowlisted chat id per line in `~/.allbert/config/channels.telegram.allowed_chats`.
3. Run `allbert-cli daemon channels add telegram`.
4. Restart the daemon if it is already running.
5. Test `/status`, `/activity`, `/trace last`, `/adapter status`, `/diagnose last`, `/utilities status`, `/approve <id>`, and `/reject <id>` from Telegram.

Telegram is structural-only for diagnosis remediation and local utility mutation. It does not start remediation, enable utilities, or run `unix_pipe`.

## unix_pipe Verification Recipe

`unix_pipe` is a tool, not a shell. The operator recipe is:

1. Enable local utilities:

   ```bash
   cargo run -p allbert-cli -- utilities discover
   cargo run -p allbert-cli -- utilities enable rg
   cargo run -p allbert-cli -- utilities enable head
   cargo run -p allbert-cli -- utilities doctor
   ```

2. Ensure the resolved binaries are allowed by exec policy. Use `settings show security.exec_allow` and add the utility id, executable name, or canonical path if your profile requires it.

3. Invoke through a model/tool path, not as a shell command. A practical local prompt is:

   ```text
   Use the unix_pipe tool to search this trusted workspace for the text "TODO" with rg, pipe it to head -n 5, and report only the five lines.
   ```

4. Verify the trace/activity surface shows `tool_name = "unix_pipe"` and per-stage utility metadata.

Every stage is preflighted before any process starts. Shell strings, globs, redirects, process substitution, and environment overrides are rejected.

## Release Validation

Default contributor validation:

```bash
cargo fmt --check
env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTC_WRAPPER cargo test -q
env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
```

Full v0.14.2 release validation:

```bash
cargo fmt --check
env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTC_WRAPPER cargo test -q
env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
env -u RUSTC_WRAPPER cargo doc --workspace
tools/check_doc_reality.sh
tools/check_kernel_size.sh --enforce
tools/check_kernel_crate_graph.sh --enforce
tools/check_kernel_import_migration.sh --enforce
tools/check_kernel_dependency_compactness.sh --enforce
```

Optional live/operator checks:

- Ollama live turn after `ollama run gemma4`.
- Hosted-provider live turn after exporting the provider key.
- Telegram live bot test after token and allowlist setup.
- Real adapter training after selecting, allowlisting, and installing a local trainer backend.

## Current Limitations

- Source-based install only.
- Terminal-first and local-user-only.
- Local IPC only; no remote control plane.
- No boot-time OS service install.
- Daily hosted-provider cost caps are per-device profile, not globally aggregated.
- Adapter-training compute caps are also per-device profile.
- Telegram proactive delivery is available; REPL, CLI, and jobs remain inspect-and-act surfaces.
- Telegram image input is photos-only; voice notes, audio, and image output are deferred.
- Local utility enablement is host-specific and excluded from profile export/sync.
- `unix_pipe` is text-only, bounded, and direct-spawn; it is not a shell runtime.
- Semantic retrieval is off by default and uses only the fake deterministic provider in this release.
- Hosted providers ignore active adapters; adapter activation is local-provider-only.
- Self-diagnosis explains by default; remediation is opt-in and review-first.
- `rust-rebuild` requires a local source checkout and never swaps the running binary automatically.
- Lua scripting is JSON-in/JSON-out only and has no host tool bridge.
- Ctrl-C does not cancel an active turn yet; the turn continues and the UI says so.
