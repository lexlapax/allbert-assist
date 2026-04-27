# Operator Feature Test Runbook

This runbook gives concrete commands for testing Allbert operator/user-facing features from v0.1 through the current v0.14.x patch line. Run commands from the repository root.

The examples use the source-tree command form:

```bash
cargo run -q -p allbert-cli --
```

If you have `allbert-cli` installed, replace that prefix with `allbert-cli`.

## Test Harness

Use a temporary profile unless you intentionally want to inspect your real profile:

```bash
cd /Users/spuri/projects/lexlapax/allbert-assist
export ALLBERT_HOME="$(mktemp -d /tmp/allbert-optest.XXXXXX)"
run() { ALLBERT_HOME="$ALLBERT_HOME" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- "$@"; }
```

For most operator tests, run setup once first:

```bash
run setup
```

Accept defaults unless a test below says otherwise. Live-provider, Telegram, and real adapter-training checks require local credentials, a local model, or local trainer binaries.

## v0.1 Basic CLI, Onboarding, Kernel, Tools, Memory, Policy

```bash
run doctor
run repl --classic
run skills list
run memory status

for f in config.toml SOUL.md USER.md IDENTITY.md TOOLS.md AGENTS.md HEARTBEAT.md; do
  test -e "$ALLBERT_HOME/$f" && echo "ok $f"
done
```

Expected: setup completes, bootstrap/config files exist, `doctor` passes, skills and memory load.

## v0.2 Daemon, Jobs, Sessions

```bash
run daemon start
run daemon status
run jobs list
run jobs template enable memory-compile
run jobs status memory-compile
run sessions list
run daemon stop
```

To actually run `memory-compile`, use a working provider, usually Ollama:

```bash
ollama run gemma4
run daemon start
run jobs run memory-compile
run jobs status memory-compile
run daemon stop
```

If the run ends with `outcome: limit` and `stop reason: hit max-turns limit`, the daemon, scheduler, session creation, and job record path still worked. That result means the live model kept calling tools or otherwise failed to produce a final answer before the job turn budget ended. Inspect the session trace and staged memory before treating it as a daemon failure:

```bash
run trace show <job-session-id>
run memory staged list
run jobs status memory-compile
```

For a release smoke, `jobs list`, `jobs template enable`, and `jobs status` are the provider-free job checks. `jobs run memory-compile` is a live-provider behavior check and may need a stronger model, a more focused job prompt, or a higher per-job `max_turns` in `~/.allbert/jobs/definitions/memory-compile.md`.

## v0.3 Agents And Intent Routing

Provider-free inspection:

```bash
run agents list
test -e "$ALLBERT_HOME/AGENTS.md" && sed -n '1,80p' "$ALLBERT_HOME/AGENTS.md"
```

Live intent routing check:

```bash
run repl --classic
```

Then type:

```text
/agents
schedule a daily review at 07:00
/status
```

Expected: agent catalog loads without provider; actual delegation/intent behavior needs a live provider.

## v0.4 AgentSkills

```bash
repo_root="$(pwd)"
skilldir="$(mktemp -d /tmp/allbert-skill.XXXXXX)"
(
  cd "$skilldir"
  printf 'Demo skill for operator smoke\nn\nn\n' | \
    ALLBERT_HOME="$ALLBERT_HOME" env -u RUSTC_WRAPPER cargo run -q --manifest-path "$repo_root/Cargo.toml" -p allbert-cli -- skills init demo-skill
)

run skills validate "$skilldir/demo-skill/SKILL.md"
run skills install "$skilldir/demo-skill"
run skills list
run skills show demo-skill
run skills disable demo-skill
run skills enable demo-skill
```

Expected: install preview appears, skill lands through the normal quarantine/install flow, and enable/disable toggles cleanly.

## v0.5 Curated Memory

Provider-free checks:

```bash
run memory status
run memory staged list
run memory stats
run memory verify
```

Expected: memory storage initializes, staged-memory listing works, and verification passes. A fresh temp profile may legitimately have no staged entries.

Live explicit-memory path:

```bash
run repl --classic
```

Then type:

```text
remember that Allbert operator tests use temporary ALLBERT_HOME profiles
review what's staged
```

Expected in v0.14.3: the schema-bound intent router drafts an explicit-memory action, Allbert creates one staged-memory candidate through the normal staging pipeline, and `review what's staged` lists it.

Failure to catch from v0.14.2 local-model testing:

```text
I could not parse the model's tool call safely: unsupported tool call shape: expected name, tool, function, or program.
```

Treat that as a regression if it returns in v0.14.3, not as proof that staged-memory listing, promotion, or search is broken. Capture the trace and inspect the v0.14.3 router/tool-parse provenance.

CLI review:

```bash
run memory staged list
run memory staged show <staged-id>
run memory promote <staged-id> --confirm
run memory stats
run memory search "temporary ALLBERT_HOME"
```

Reject path:

```bash
run memory reject <staged-id> --reason "test rejection"
run memory verify
```

## v0.6 Hardening, Session Durability, Cost Cap, Recovery

```bash
run memory verify
run memory recovery-gc
run settings show limits.daily_usd_cap
run settings show learning.compute_cap_wall_seconds
run config restore-last-good
```

REPL cost flow:

```bash
run repl --classic
```

Then type:

```text
/cost
/cost --override "operator test"
```

Expected: override requires an explicit reason and applies to one turn only.

## v0.7 Channels, Telegram, Normalized Tools, Web-Learning Posture

Provider-free Telegram config smoke:

```bash
run daemon channels add telegram
run daemon channels status telegram
run daemon channels remove telegram
```

Parser/unit smoke:

```bash
env -u RUSTC_WRAPPER cargo test -q telegram_command_parser
```

Live Telegram requires credentials:

`TELEGRAM_BOT_TOKEN` is the token from Telegram's BotFather. In Telegram,
start a chat with `@BotFather`, run `/newbot`, follow the prompts, and copy the
token it returns.

`TELEGRAM_CHAT_ID` is the numeric id of the Telegram chat that is allowed to
talk to your bot. To discover it, send a message to your bot first, then inspect
the bot updates:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

Look for `message.chat.id` in the `getUpdates` response. For a direct chat it
is usually a positive number like `123456789`. For a group or supergroup it is
usually negative, often like `-1001234567890`. Use the whole number exactly as
Telegram reports it. If `getUpdates` is empty, send `/start` or any message to
the bot, then run it again.

```bash
mkdir -p "$ALLBERT_HOME/secrets/telegram" "$ALLBERT_HOME/config/channels.telegram"
printf '%s\n' "$TELEGRAM_BOT_TOKEN" > "$ALLBERT_HOME/secrets/telegram/bot_token"
printf '%s\n' "$TELEGRAM_CHAT_ID" > "$ALLBERT_HOME/config/channels.telegram.allowed_chats"

run daemon channels add telegram
run daemon restart
run daemon channels status telegram
run identity show
run identity add-channel telegram "$TELEGRAM_CHAT_ID"
run identity show
```

Expected: `daemon channels status telegram` reports `enabled: yes`,
`state: configured`, and detail containing `allowlisted chats: 1`.
`identity show` may initially warn that the Telegram allowlisted sender is not
mapped into identity continuity; `identity add-channel telegram
"$TELEGRAM_CHAT_ID"` promotes that migration candidate, and the next
`identity show` should include `telegram:<id>` under `channels` without that
warning. Then send `/status`, `/activity`, `/approve <id>`, and `/reject <id>`
in Telegram.

## v0.8 Continuity, Identity, Inbox, Profile Sync, Heartbeat

```bash
run identity show
run heartbeat show
run inbox list
run identity add-channel telegram "$TELEGRAM_CHAT_ID"   # if identity show lists telegram:<id> as a migration candidate
run heartbeat suggest --channel telegram                 # optional: writes a reviewed Telegram heartbeat template

archive="/tmp/allbert-profile-test.tgz"
run profile export "$archive"

import_home="$(mktemp -d /tmp/allbert-import.XXXXXX)"
ALLBERT_HOME="$import_home" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- profile import "$archive" --overlay
ALLBERT_HOME="$import_home" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- identity show
ALLBERT_HOME="$import_home" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- heartbeat show
```

Expected: identity/profile artifacts import; secrets, sockets, logs, and local utility enablement remain excluded.

If the imported profile has a Telegram identity binding but not the local
allowlist, `identity show` may warn:

```text
telegram sender <id> is present in identity/user.md but missing from .../config/channels.telegram.allowed_chats
```

That means continuity imported the identity binding, but this destination
profile is not configured to accept Telegram from that chat. For a profile-sync
smoke, the warning is informational. If this destination should use Telegram,
write the bot token and allowlist locally:

```bash
mkdir -p "$import_home/secrets/telegram" "$import_home/config/channels.telegram"
printf '%s\n' "$TELEGRAM_BOT_TOKEN" > "$import_home/secrets/telegram/bot_token"
printf '%s\n' "$TELEGRAM_CHAT_ID" > "$import_home/config/channels.telegram.allowed_chats"
ALLBERT_HOME="$import_home" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- identity show
```

If this destination should not use Telegram, remove that imported binding:

```bash
ALLBERT_HOME="$import_home" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- identity remove-channel telegram "$TELEGRAM_CHAT_ID"
```

Fresh temp profiles default `HEARTBEAT.md` to `primary_channel: repl`.
`heartbeat show` may warn that `repl` is not proactively deliverable because
only Telegram currently receives unsolicited inbox nags/check-ins. That warning
is expected for provider-free continuity smokes. If you want real proactive
delivery, configure Telegram, map identity with `identity add-channel telegram
<id>`, then edit `HEARTBEAT.md` or use `heartbeat suggest --channel telegram`
and review the generated template. If you do not want proactive nags, leave the
warning alone or set `inbox_nag.enabled: false`.

## v0.9 Contributor And Codex Web Readiness

```bash
cargo fmt --check
env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTC_WRAPPER cargo test -q
env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
```

Expected: provider-free green gate.

## v0.10 Provider Expansion

Provider-free config inspection:

```bash
run settings show model
run settings set model.provider ollama
run settings set model.model_id gemma4
run settings show model
```

Local live Ollama:

```bash
ollama run gemma4
run repl --classic
```

Then type:

```text
/model ollama gemma4
say hello
```

Gemma4 may spend part of the output budget on hidden thinking. Allbert's Ollama
provider disables hidden thinking for chat requests because the runtime does not
surface Ollama `message.thinking` as assistant output. If a manually lowered
`model.max_tokens` setting still causes Ollama to stop at length before
returning visible content, Allbert should surface a clear Ollama provider error
rather than a blank assistant reply.

Hosted live:

```bash
export OPENAI_API_KEY=...
run settings set model.provider openai
run settings set model.model_id <model-id>
run settings set model.api_key_env OPENAI_API_KEY
run repl --classic
```

## v0.11 TUI, Telemetry, Adaptive Memory, Personality Digest

```bash
run telemetry --json
run activity --json
run memory routing show
run memory search "anything" --tier episode
run memory search "anything" --tier fact
run learning digest --preview
run repl --tui
```

Expected: telemetry JSON renders, digest preview does not install `PERSONALITY.md`, and TUI status/activity panes render.

## v0.12 Self-Improvement, Skill Authoring, Lua

```bash
run self-improvement config show
run self-improvement config set --source-checkout /Users/spuri/projects/lexlapax/allbert-assist
run self-improvement gc --dry-run
run skills show skill-author
run settings show scripting
```

Live patch approval flow:

```bash
run repl --classic
```

Ask Allbert to use `rust-rebuild` for a tiny doc/code change. Then inspect:

```bash
run inbox list
run inbox show <patch-approval-id>
run self-improvement diff <patch-approval-id>
```

Lua gate inspection:

```bash
run settings set scripting.engine lua
run settings show scripting
run settings show security.exec_allow
```

Expected: self-improvement uses sibling worktrees; install remains explicit; Lua stays opt-in.

## v0.12.1 Operator UX Polish

```bash
run settings list
run settings show repl.tui
run settings explain repl.tui.spinner_style
run settings set repl.tui.spinner_style off
run settings reset repl.tui.spinner_style
run activity
run doctor
```

TUI narrow-terminal check:

```bash
COLUMNS=70 LINES=20 ALLBERT_HOME="$ALLBERT_HOME" env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- repl --tui
```

Expected: settings descriptors explain/validate, reset works, and TUI remains usable or falls back cleanly.

## v0.12.2 Tracing And Replay

```bash
run settings show trace
run settings set trace.enabled true
run settings set trace.capture_messages true
run daemon start
```

Generate a trace with a live turn:

```bash
run repl --classic
```

Type a simple prompt, then exit.

Inspect/export:

```bash
run trace list
run trace show
run trace tail
run trace export <session-id> --format otlp-json
run trace gc --dry-run
```

Redaction posture:

```bash
run settings set trace.redaction.tool_args summary
run settings set trace.redaction.tool_results drop
run settings set trace.redaction.provider_payloads summary
run settings show trace
```

## v0.13 Personalization And Adapters

Safe provider-free checks:

```bash
run adapters list
run adapters status
run adapters history
run adapters training preview
run settings show learning.adapter_training
```

Explicit fake-backend smoke in temp profile:

```bash
run settings set learning.adapter_training.enabled true
run settings set learning.adapter_training.allowed_backends '["fake"]'
run settings set learning.adapter_training.default_backend fake
run settings set security.exec_allow '["fake-adapter-trainer"]'
run adapters training preview
run adapters training start
run inbox list --kind adapter-approval
```

Real training additionally requires a real local backend, exec allowlist, and compute cap.

## v0.14 Self-Diagnosis, Local Utilities, unix_pipe

Diagnosis:

```bash
run diagnose run
run diagnose list
run diagnose show <diagnosis-id>
run diagnose list --offline
```

Utilities:

```bash
run utilities discover
run utilities enable rg
run utilities enable jq
run utilities list
run utilities show rg
run utilities doctor
run utilities disable jq
```

`unix_pipe` is tool-only. Live test:

```bash
run utilities enable rg
run utilities enable head
run utilities doctor
run repl --classic
```

Then ask:

```text
Use the unix_pipe tool to search this trusted workspace for "TODO" with rg, pipe it to head -n 5, and report only the five lines.
```

Then verify:

```bash
run activity
run trace show
```

## v0.14.1 Reconciliation Fixes

Doctor/config checks:

```bash
run doctor
run settings show intent.tool_call_retry_enabled
run settings show learning.adapter_training
run adapters training preview
```

Disabled-training fail-closed check:

```bash
run settings set learning.adapter_training.enabled false
run adapters training start
```

Expected: clear failure, no silent fake trainer.

Parser/unit checks:

```bash
env -u RUSTC_WRAPPER cargo test -q tool_call_parser
```

Remediation candidate path:

```bash
run settings set self_diagnosis.allow_remediation true
run diagnose run --remediate code --reason "operator reconciliation smoke"
run inbox list
```

Expected: remediation routes through review surfaces, not direct install.

## v0.14.2 Kernel Core/Services Split And Daemon Reliability

No operator behavior change; run contributor/release gates:

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

Repeated daemon reliability check:

```bash
for i in 1 2 3 4 5; do
  echo "daemon integration pass $i"
  env -u RUSTC_WRAPPER cargo test -q -p allbert-daemon --test m1_daemon || exit 1
done
```

Expected: no local socket `Operation not permitted` failures under default parallel execution.

## v0.14.3 Conversational Scheduling Reliability

v0.14.3 is the shipped operator reliability patch. The foundation is a schema-bound intent router that runs before full prompt assembly. The release-blocking smoke is the local-model scheduling transcript that exposed the bug:

```bash
run repl --classic
```

Then type:

```text
schedule a daily review at 07:00
```

Expected in v0.14.3: the router drafts a guarded `schedule_upsert` action and Allbert shows the structured durable scheduling confirmation in the same flow, not a plain prose `Shall I proceed?` prompt. Approve with `y`, then verify:

```bash
run jobs status daily-review
```

Expected: the job exists with a daily 07:00 schedule.

Failure to catch: the model asks `Shall I proceed?`, the operator types `yes`, and the next turn fails with `unsupported tool call shape: name input/arguments is missing`. That is the v0.14.3 blocking regression.

Safe fallback if a local model still fails to produce a usable schedule action after the bounded retry:

```bash
cat > "$ALLBERT_HOME/daily-review.md" <<'EOF'
---
name: daily-review
description: Daily review
enabled: true
schedule: "@daily at 07:00"
report: always
max_turns: 3
---

Run a concise daily review.
EOF

run jobs upsert "$ALLBERT_HOME/daily-review.md"
run jobs status daily-review
```

## v0.14.3 Explicit Memory Reliability

The v0.5 curated-memory smoke no longer depends on a local model producing a
valid `stage_memory` tool call for the first staging step. In v0.14.3, the
schema-bound router drafts explicit-memory staging actions before the full
assistant prompt:

```text
remember that Allbert operator tests use temporary ALLBERT_HOME profiles
please remember operator release smokes use temp profiles
remember: staged memory stays review-first
```

Expected in v0.14.3: each high-confidence router decision creates one staged
`explicit_request` entry with a non-empty summary and does not promote it
directly to durable memory. Verify with:

```bash
run memory staged list
run memory staged show <staged-id>
```

Failure to catch from v0.14.2: the first turn routes through the full model and
fails before staging. That is now a v0.14.3 regression, not a failure of
`memory staged list`, `memory promote`, or `memory search`.

## v0.14.3 OpenAI Responses History Reliability

This is an optional credentialed smoke. It requires `OPENAI_API_KEY` and should
be run only when you intend to test the live OpenAI provider path:

```bash
run repl --classic
```

Then type:

```text
/model openai <model-id> OPENAI_API_KEY
hello
say one more thing
```

Expected in v0.14.3: both turns succeed, including the second turn
after assistant history exists. The failure to catch is:

```text
Invalid value: 'input_text'. Supported values are: 'output_text' and 'refusal'.
param: input[1].content[0]
```

That error means assistant history was serialized as `input_text` instead of
OpenAI Responses `output_text`. In v0.14.3 this is a provider regression. For
provider-free implementation validation, run the OpenAI provider mock tests that
capture the request body and prove user text uses `input_text`, assistant
history uses `output_text`, user images use `input_image`, and assistant images
are rejected locally.

## v0.14.3 Gemini Live-Provider Response Reliability

This is an optional credentialed smoke. It requires `GEMINI_API_KEY` and should
be run only when you intend to test the live Gemini provider path:

```bash
run repl --classic
```

Then type:

```text
/model gemini gemini-2.5-flash-lite GEMINI_API_KEY
hello
```

Expected in v0.14.3: the turn succeeds, or the failure is a clear provider
status such as quota exhaustion or temporary high demand. The failure to catch
is a local decoder error:

```text
error decoding response body
```

That error means the Gemini response parser rejected a live response shape
instead of extracting text from text-bearing parts and ignoring non-text parts.
For provider-free implementation validation, run the Gemini provider mock tests
that include unknown non-text response parts before a text part.
