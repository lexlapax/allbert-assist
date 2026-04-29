# Operator Feature Test Runbook

This runbook gives concrete commands for testing Allbert operator/user-facing
features from v0.1 through the current v0.15.0 release. Run commands from the
repository root.

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

Accept defaults unless a test below says otherwise. When setup asks for trusted
filesystem roots, accept the current repository root if you want to run the RAG,
filesystem-tool, self-improvement, and `unix_pipe` examples against this source
checkout. Live-provider, Telegram, URL-ingestion, and real adapter-training
checks require network access, credentials, a local model, or local trainer
binaries.

Use this runbook in three layers:

- Provider-free smoke: run the CLI/daemon/settings/storage commands that do not
  call an LLM, Telegram, hosted API, live URL, or trainer binary.
- Local-live smoke: add Ollama/Gemma4 turns, Ollama `embeddinggemma` vector
  RAG, TUI interaction, and local process/tool checks.
- Credentialed/operator smoke: add hosted providers, Telegram, URL ingestion,
  and real adapter training only when you intentionally want those systems
  exercised.

For each feature below, verify three things:

- The command or interaction exits cleanly and prints a specific state, count,
  id, manifest path, approval id, session id, or error message.
- The state lands in the expected owner: config in `config.toml`, jobs in
  `jobs/definitions` or `jobs/runs`, skills in `skills/installed`, memory in
  `memory/`, traces in `sessions/<id>/trace.jsonl`, RAG in
  `index/rag/rag.sqlite` plus user manifests under `rag/collections/user/`.
- Guardrails are visible: risky changes ask for confirmation, staged or review
  content is not promoted automatically, trusted roots are enforced, and
  Telegram or other reduced-capability channels do not gain mutation powers
  they should not have.

When a live turn fails, capture the state before rerunning:

```bash
run activity
run trace show
run inbox list
run daemon logs --lines 120
```

Expected live-model failures are called out explicitly. Treat any unlabelled
panic, blank assistant answer, silent state mutation, missing confirmation, or
secret/raw-token leak as a regression.

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

What to verify:

- Setup writes `config.toml`, bootstrap markdown files, seeded skills, memory
  folders, and daemon defaults under the temporary `ALLBERT_HOME`.
- `doctor` reports actionable warnings instead of panics. A missing hosted API
  key is acceptable when the profile uses local Ollama or you are only running
  provider-free checks.
- `repl --classic` starts after setup and exits cleanly with `/exit`.
- `skills list` includes first-party skills, and `memory status` initializes
  memory without requiring a live provider.

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
run jobs template enable memory-compile
run jobs run memory-compile
run jobs status memory-compile
run daemon stop
```

`jobs enabled: no` in daemon status means scheduled background ticks are
disabled for the profile. Explicit manual commands such as `jobs run
memory-compile` are still allowed after the job definition exists.

If the run ends with `outcome: limit` and `stop reason: hit max-turns limit`, the daemon, scheduler, session creation, and job record path still worked. That result means the live model kept calling tools or otherwise failed to produce a final answer before the job turn budget ended. Inspect the session trace and staged memory before treating it as a daemon failure:

```bash
run trace show <job-session-id>
run memory staged list
run jobs status memory-compile
```

For a release smoke, `jobs list`, `jobs template enable`, and `jobs status` are the provider-free job checks. `jobs run memory-compile` is a live-provider behavior check and may need a stronger model, a more focused job prompt, or a higher per-job `max_turns` in `~/.allbert/jobs/definitions/memory-compile.md`.

What to verify:

- `daemon status` shows the daemon socket path and running state for this temp
  profile, not your real profile.
- Enabling a template creates a markdown job definition with frontmatter; it
  does not start running until explicitly scheduled or invoked.
- `jobs status` reports enabled/paused, schedule, recent run outcome, failure
  streak, and last stop reason.
- `sessions list` shows daemon-owned sessions after jobs or interactive turns.
- `daemon stop` leaves no stale daemon for this `ALLBERT_HOME`.

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

What to verify:

- `agents list` and generated `AGENTS.md` agree on root/sub-agent metadata.
- `/agents` in the REPL shows the same catalog without forcing a model call.
- `/status` exposes the last resolved intent after a live turn.
- Scheduling and memory capture are still guarded actions. Intent routing may
  draft the action, but durable mutation still goes through the confirmation or
  review path described in later sections.

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

What to verify:

- `skills validate` fails closed for malformed `SKILL.md` files and succeeds
  for the generated canonical AgentSkills tree.
- `skills install` shows a preview before installing. The installed copy lands
  under `skills/installed/`; incoming downloads/clones stay quarantined until
  approved.
- `skills list` reports enabled state and source/provenance. `disable` removes
  the skill from activation without deleting it, and `enable` restores it.
- Skill scripts, when present, remain governed by `security.exec_allow` and the
  skill `allowed-tools` policy.

## v0.5 Curated Memory

Provider-free checks:

```bash
run memory status
run memory staged list
run memory stats
run memory verify
```

What to verify:

- `memory status`, `stats`, and `verify` agree about durable, staged, episode,
  fact, and index state. A fresh temp profile may legitimately have no staged
  entries.
- Staged candidates are visible in `memory/staging/` and do not appear as
  approved durable notes until promoted.
- Promotion moves the candidate into durable memory and makes it searchable;
  rejection records the reason and keeps the item out of durable search.
- Forget/recovery flows remain explicit. A search hit should not disappear from
  durable memory without an explicit `forget` or review action.

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

In v0.15, memory-query prompt snippets are retrieved through RAG when eligible,
but the memory CLI remains the source-of-truth review surface. Do not treat a
RAG search hit as promotion.

Failure to catch from v0.14.2 local-model testing:

```text
I could not parse the model's tool call safely: unsupported tool call shape: expected name, tool, function, or program.
```

Treat that as a regression if it returns in v0.14.3, not as proof that staged-memory listing, promotion, or search is broken. Capture the trace and inspect the v0.14.3 router/tool-parse provenance.

CLI review:

The CLI review commands below require at least one staged candidate. On a fresh
temp profile, `memory staged list` may legitimately print `no staged memory
entries`. In that case, run the live explicit-memory path above first, then copy
the staged id from the `id:` line in `memory staged list`.

For a realistic review pass, stage two candidates before returning to the CLI:

```text
remember that Allbert operator tests use temporary ALLBERT_HOME profiles
remember that the v0.5 reject-path smoke uses a disposable staged candidate
review what's staged
```

Do not choose ids by display order. `memory staged list` prints newest
candidates first, so the second `remember that ...` turn usually appears above
the first one. Choose ids by the candidate summary or excerpt:

- Use the id for `Allbert operator tests use temporary ALLBERT_HOME profiles`
  as `<promote-staged-id>`, because the search command below validates that
  promoted note.
- Use the id for `the v0.5 reject-path smoke uses a disposable staged
  candidate` as `<reject-staged-id>`.

Promotion moves the staged candidate out of the staging queue, so the reject
path needs a different staged id.

```bash
run memory staged list
run memory staged show <promote-staged-id>
run memory promote <promote-staged-id> --confirm
run memory stats
run memory search "temporary ALLBERT_HOME"
```

Expected: the search returns the promoted `Allbert operator tests use temporary
ALLBERT_HOME profiles` note. If it returns no results, first confirm that the
temp-profile candidate was promoted rather than the disposable reject-path
candidate.

Reject path:

```bash
run memory staged show <reject-staged-id>
run memory reject <reject-staged-id> --reason "test rejection"
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

What to verify:

- `memory verify` and `recovery-gc` do not mutate approved notes unexpectedly.
- `config restore-last-good` either restores a real backup or explains that no
  backup is available.
- `/cost --override <reason>` requires a non-empty reason, applies to exactly
  one turn, and records the override in the normal cost/inbox surfaces.
- Restarting the daemon preserves completed sessions and job records; incomplete
  tool calls should rewind to a safe turn boundary rather than replaying an
  unsafe mutation.

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

Live Telegram requires credentials. `TELEGRAM_BOT_TOKEN` is the token from
Telegram's BotFather. In Telegram, start a chat with `@BotFather`, run
`/newbot`, follow the prompts, and copy the token it returns. Then send
`/start` or any short message to your new bot from the Telegram chat you want
to allow.

Primary setup path:

```bash
export TELEGRAM_BOT_TOKEN=...
run daemon channels setup telegram --latest --yes
run daemon restart
run daemon channels status telegram
run identity show
```

Expected: setup prints `Telegram setup applied`, a `chat id: ...` line, and
`bot: @...`. `daemon channels status telegram` reports `enabled: yes`,
`state: configured`, and detail containing `allowlisted chats: 1`.
`identity show` should include `telegram:<id>` under `channels` without a
Telegram migration warning. Runtime sender keys may include both chat id and
Telegram user id, but the documented chat-id binding is sufficient. Then send
`/status`, `/activity`, `/approve <id>`, and `/reject <id>` in Telegram.
If later runbook sections need `TELEGRAM_CHAT_ID`, set it to the `chat id:`
value printed by setup.

If setup reports no candidates, send `/start` or any message to the bot and
rerun it. If setup reports multiple candidates, rerun with `--latest` after a
fresh DM or use `--chat-id <id>` when intentionally configuring a group chat.

Manual fallback for troubleshooting:

```bash
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getMe"
curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates"
```

Do not use the bot id from `getMe.result.id`, the top-level `update_id`, the
per-message `message.message_id`, or `message.from.id` for
the allowlist. Use `message.chat.id`. For example, in this shape:

```json
{
  "update_id": 111,
  "message": {
    "message_id": 17,
    "from": { "id": 222 },
    "chat": { "id": 333, "type": "private" },
    "text": "hello bot"
  }
}
```

the Telegram message id is `17`, but the allowlisted chat id is `333`. That
means manual setup should use:

```bash
export TELEGRAM_CHAT_ID=333
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

What to verify:

- Adding/removing the Telegram channel changes daemon channel state without
  changing identity bindings unless you use the setup helper or explicitly run
  `identity add-channel`.
- Telegram refuses chats that are not in
  `config/channels.telegram.allowed_chats`.
- `/status` and `/activity` show compact daemon-owned state without local file
  dumps, raw trace payloads, or secret values.
- Approval resolution works cross-surface: create or locate an approval in one
  surface, then accept/reject it from Telegram, CLI, TUI, or REPL and verify the
  other surfaces no longer show it as pending.
- Explicit-intent web learning is not ambient browsing. If you ask Allbert to
  fetch/search the web, verify any durable memory write still goes through the
  documented `record_as` or staged-memory path.

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
`heartbeat show` may warn that the enabled `inbox_nag` targets `repl` because
only Telegram currently receives unsolicited inbox nags/check-ins. This is not
data loss and does not block identity, inbox, or profile export/import testing.
If v0.7 Telegram setup already added the identity binding, `identity
add-channel telegram "$TELEGRAM_CHAT_ID"` may simply report that the binding
already exists.

Expected warning shape for the default local-only heartbeat:

```text
inbox_nag targets `repl`, but proactive messages can only be delivered to `telegram`; run `heartbeat suggest --channel telegram`, review the generated file, and replace HEARTBEAT.md, or set `inbox_nag.enabled: false` to stay local-only
```

If you want real proactive delivery, configure Telegram, ensure identity
includes `telegram:<id>`, then edit `HEARTBEAT.md` or use
`heartbeat suggest --channel telegram` and review the generated template. If
you do not want proactive nags, leave the warning alone or set
`inbox_nag.enabled: false`.

What to verify:

- `profile export` excludes secrets, sockets, logs, local utility enablement,
  and host-specific adapter artifacts unless an option explicitly includes an
  allowed artifact.
- `profile import --overlay` preserves identity, memory, heartbeat, jobs, and
  config posture without requiring the destination machine to have the same
  Telegram token or trusted local utilities.
- `identity show` distinguishes continuity bindings from channel allowlists; a
  warning about a missing local allowlist is not data loss.
- `heartbeat suggest` writes a reviewed template, not a hidden scheduled job.
  Proactive delivery remains Telegram-only in this release.

## v0.9 Contributor And Codex Web Readiness

```bash
cargo fmt --check
env -u RUSTC_WRAPPER cargo clippy --workspace --all-targets -- -D warnings
env -u RUSTC_WRAPPER cargo test -q
env -u RUSTC_WRAPPER cargo run -q -p allbert-cli -- --help
```

Expected: provider-free green gate.

What to verify:

- Run the gate from a clean source checkout and with `RUSTC_WRAPPER` unset.
- Failures in this section are contributor-environment failures, not operator
  profile failures. Fix them before running live-provider or release smokes.
- `cargo run -q -p allbert-cli -- --help` should complete without setup or
  provider credentials.

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
run daemon restart
run repl --classic
```

Then type:

```text
/model ollama gemma4
say hello
web search for today's top news
hello what's today's top news?
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

What to verify:

- `settings show model` reflects the selected provider/model/api-key env
  without erasing unrelated comments or config tables.
- Local Ollama turns require a running Ollama service and a pulled chat model.
  Allbert should surface provider errors clearly if Ollama is stopped or the
  model is missing.
- The explicit web-search smoke and the current-info smoke should call
  `web_search` when that tool is available; each transcript should include
  `[activity] calling tool web_search`. With web access available they should
  answer from current search results. Without web access, they should surface a
  clear web/network/policy error. A no-tool prose apology such as "I cannot
  browse" is a failure, distinct from a real web/network/policy error.
- If a tool is denied unexpectedly, run `/telemetry` in the REPL before
  continuing. After ordinary auto-routed memory turns, active skills should
  return to `(none)` unless the operator explicitly activated a session skill.
  If the daemon has been running across a local source patch, restart it before
  retesting so the REPL is attached to the rebuilt runtime.
- Hosted turns use the configured `api_key_env`; API keys should not appear in
  traces, telemetry, activity, or errors.
- Session-local `/model ...` changes affect the attached session only. Persistent
  default model changes should be made through `settings set`.

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

What to verify:

- `telemetry --json` includes model, cost, memory, skill, inbox, trace, and
  adapter posture with no secret values.
- `activity --json` reports the current daemon phase and next-action hints; it
  should not guess from frontend timers.
- Episode and fact search tiers are labelled as recall/approved fact context,
  not ordinary durable note text.
- `learning digest --preview` writes or prints a preview only. It must not
  install `PERSONALITY.md` unless you run the accepted install path.
- TUI status line stays readable and updates model/context/cost/memory/intent
  state during turns.

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

What to verify:

- Self-improvement source checkout must point at a local source tree. Allbert
  proposes patches in sibling worktrees and never swaps the running binary.
- Patch approvals show bounded context in the inbox; full diffs remain artifact
  backed and installation is a separate explicit command.
- `skill-author` drafts skills into the same quarantine/review path as external
  skills. It must not directly install prompt-authored skills.
- Lua remains disabled unless both `[scripting].engine = "lua"` and exec policy
  allow it. Lua scripts are JSON-in/JSON-out only and cannot call host tools
  except through explicitly allowed Allbert tool surfaces.

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

What to verify:

- `settings list/show/explain` groups supported settings and prints allowed
  values, defaults, and remediation hints.
- `settings set` validates values and preserves unrelated TOML keys/comments as
  much as the path-preserving writer allows.
- `settings reset` restores the known default for that key without whole-file
  rewrites.
- Narrow TUI startup should either render usable panels or fall back with a
  clear message; it should not corrupt terminal state.

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

What to verify:

- Trace capture can be enabled through settings and survives daemon restart.
- `trace list`, `show`, and `tail` read session-local trace files from
  `sessions/<session-id>/trace.jsonl`.
- `trace export --format otlp-json` writes a local file export only; Allbert
  does not send traces to a network collector.
- Redaction applies on read/export. API keys, Telegram tokens, and provider
  payloads configured as `summary` or `drop` should not appear verbatim.
- `trace gc --dry-run` reports what would be removed without deleting active
  traces.

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

What to verify:

- Disabled training fails closed and does not silently use the fake backend.
- Fake-backend training is allowed only when both
  `learning.adapter_training.allowed_backends` and `security.exec_allow`
  permit it.
- Starting training creates a run record and an `adapter-approval` inbox item;
  accepting installs the adapter artifact but does not activate it unless you
  explicitly run the activation command.
- Hosted providers ignore active adapters with a clear notice. Local adapter
  activation is local-provider-only and base-model-pinned.
- Profile export excludes adapter weights by default.

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

What to verify:

- `diagnose run` writes a bounded report artifact under the current session's
  diagnostics directory. By default it explains only.
- Remediation requires `self_diagnosis.allow_remediation = true` and an
  explicit `--remediate <code|skill|memory> --reason <text>` command.
- Memory-shaped remediation creates staged memory only; code-shaped remediation
  creates `patch-approval`; skill-shaped remediation uses skill quarantine.
- `utilities discover` finds candidates but enables nothing automatically.
- `utilities enable` is host-local and profile-export excluded.
- `unix_pipe` uses enabled utility ids, direct-spawn argv, trusted cwd, byte
  caps, timeout caps, and no shell parsing. Globs, redirects, env overrides,
  and arbitrary shell strings should be rejected.

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

What to verify:

- `tool_call_parser` tests cover provider/tool-call schema variants that local
  models may emit.
- Disabled adapter training produces an explicit error and no run directory.
- Diagnosis remediation candidate generation may call a provider when
  configured, but the resulting artifact still routes through the same review
  surface as a human-requested remediation.
- OpenAI/Gemini/Ollama compatibility repairs should produce clear provider
  errors instead of blank assistant output or local decoder panics.

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

What to verify:

- The release gates still pass after source-tree changes, especially
  `tools/check_doc_reality.sh` when docs mention shipped behavior.
- Kernel size, crate graph, import migration, and dependency compactness gates
  stay green. If a gate fails, fix the architecture or docs rather than
  loosening the gate casually.
- Daemon tests can run repeatedly without serial-test workarounds or stale
  socket cleanup.

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

What to verify:

- The first turn should produce a structured schedule confirmation, not a vague
  prose-only approval.
- Approval creates or updates exactly one markdown job definition.
- Re-running `jobs status daily-review` should show the schedule and recent
  state without needing to inspect JSONL logs.
- Rejecting the confirmation should leave no job definition behind.

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

What to verify:

- Explicit-memory turns stage one candidate per high-confidence request.
- The staged candidate has a non-empty summary and provenance showing it came
  from an explicit request.
- No durable note is created until `memory promote <id> --confirm` or the
  equivalent review flow runs.
- Rejecting the staged candidate keeps it out of durable/fact search and
  records the rejection reason.

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

What to verify:

- The second OpenAI turn succeeds after assistant history exists.
- If the live API rejects the request for quota/model reasons, the error should
  be a provider status, not a local serialization shape error.
- Trace/provider debug output should not include the API key value.

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

What to verify:

- A live Gemini text response with extra non-text parts still returns the text
  part.
- Quota, safety, or temporary demand errors surface as provider failures with
  status/context.
- A local `error decoding response body` is a regression unless the upstream
  payload is genuinely malformed JSON.

## v0.15.0 Vector RAG, Recall, And Help

v0.15.0 adds a daemon-owned SQLite RAG index with provider-free lexical search
and real local vectors through Ollama embeddings plus `sqlite-vec`. The release
smoke should prove both the operator surfaces and the turn-control invariants,
because RAG is prompt evidence and retrieval infrastructure, not a new action
authority.

Configuration and bootstrap smoke:

```bash
run settings show rag
run settings show rag.vector
run settings show rag.index
run settings show rag.ingest
run skills show rag
```

Expected: RAG settings render from the central settings hub, vectors are
disabled unless you enable them, URL-ingestion limits are visible, and the
first-party `rag` skill is installed on a fresh profile.

Provider-free lexical smoke:

```bash
run rag rebuild --no-vectors
run rag status
run rag search "configure Telegram" --mode lexical
```

Expected: the rebuild completes, `rag status` reports indexed source/chunk
counts, and lexical search returns bounded labelled snippets from current
operator docs, command descriptors, settings descriptors, or skill metadata.

What to verify:

- `~/.allbert/index/rag/rag.sqlite` exists after rebuild and can be deleted and
  recreated from source truth.
- `rag status` reports system collection counts, source counts, chunk counts,
  vector posture, last run posture, and stale/degraded state.
- Lexical search works without Ollama, hosted providers, or network access.
- Results include source labels such as docs, commands, settings, skills,
  memory, facts, episodes, sessions, or collection names; snippets are bounded
  and not raw unbounded file dumps.

Local vector smoke, outside default CI:

```bash
ollama pull embeddinggemma
run settings set rag.vector.enabled true
run rag rebuild --vectors
run rag doctor
run rag search "configure Telegram" --mode hybrid
```

Expected: the vector phase records the discovered embedding dimension, hybrid
search includes vector/lexical posture in result metadata, and lexical fallback
remains usable if Ollama is stopped or the vector phase is skipped.

What to verify:

- `rag doctor` distinguishes healthy vectors, disabled vectors, stale vectors,
  and degraded lexical fallback.
- If `embeddinggemma` is missing, Allbert prints an actionable Ollama/model
  error and lexical search remains usable when fallback is enabled.
- Rebuilding after changing the embedding model invalidates stale vectors rather
  than mixing dimensions.
- Hybrid search should still return labelled evidence; vector scores must not
  remove source labels or prompt-eligibility gates.

Turn-flow smoke in REPL or TUI:

```text
help me configure Telegram
what do you remember about temporary ALLBERT_HOME profiles?
hello, just chatting for a minute
```

Expected:

- Channel input attaches to the daemon session and enters the normal kernel
  turn runner.
- The kernel emits classification/progress events before prompt evidence is
  rendered.
- Any pre-router RAG hint is tiny, lexical-only, and limited to command,
  settings, operator-help, and bounded skill metadata sources.
- The schema-bound router still owns intent classification and guarded action
  drafts.
- Terminal router actions still win; RAG does not authorize, replace, or bypass
  schedule, memory, approval, or other guarded action checks.
- Post-router RAG runs only when eligible: help/meta turns search docs,
  commands, settings, and skills; memory-query turns search durable memory,
  approved facts, episodes, and session summaries; ordinary task turns retrieve
  only when local context is useful; casual chat usually skips RAG.
- Prompt assembly keeps the memory synopsis and ephemeral/session summary, but
  durable/fact/episode/session snippets come through RAG so Tantivy memory
  prefetch and RAG do not inject duplicate snippets for the same content.
- RAG snippets render as labelled evidence with source ids and freshness
  posture, not as hidden instructions or unquestionable truth.
- The root model can use that evidence and may call the capped read-only
  `search_rag` tool for a second retrieval pass.
- File/process/search-like tool evidence may trigger at most one capped RAG
  refresh for the turn.
- RAG indexing runs only through daemon-owned maintenance: protocol v7
  status/search/rebuild/GC commands and scheduled stale-only runs, not
  prompt-authored job definitions.

How to observe it:

```bash
run settings set trace.enabled true
run settings set trace.capture_messages true
run repl --classic
run trace show
run activity
find "$ALLBERT_HOME/jobs/definitions" -iname '*rag*' -print
```

What to verify:

- Help/meta turns include compact RAG evidence before the root answer; ordinary
  chat should not suddenly cite docs or memory.
- Memory-query turns keep the memory synopsis but use RAG for durable/fact/
  episode/session snippets. You should not see duplicate Tantivy and RAG
  snippets for the same durable content.
- A schedule or explicit-memory terminal router action should complete through
  its guarded path before RAG prompt evidence could change the action.
- The `find ... '*rag*'` command should print no prompt-authored RAG job
  definitions. RAG maintenance is service-owned.

Channel smoke:

```text
/rag status
/rag search settings
/rag rebuild --stale-only
```

Expected: REPL/TUI support status, search, rebuild, and GC through the daemon.
Protocol v7 has rebuild-cancel support for clients that wire it. Telegram
supports `/rag status` and `/rag search <query>` only; rebuild and GC stay on
local terminal surfaces.

What to verify:

- REPL/TUI `/rag` commands report daemon-owned status and do not read SQLite
  directly from the frontend.
- Telegram `/rag status` and `/rag search <query>` return bounded structural
  results and refuse rebuild, GC, collection mutation, or URL fetch flows.
- Older protocol clients can attach without seeing v7-only RAG messages.

v0.15 M7 collection-aware smoke:

```bash
run rag collections list
run rag collections create release-docs --source docs/operator
run rag collections ingest release-docs --no-vectors
run rag rebuild --collection-type user --collection release-docs --vectors
run rag collections show release-docs --collection-type user
run rag collections search release-docs "configure Telegram" --mode lexical
run rag search "configure Telegram" --collection-type user --collection release-docs
```

Expected: system collections remain searchable with omitted collection filters,
the user collection search returns only `user/release-docs` snippets, prompt
context does not include user collection snippets until the collection is
explicitly attached to the task/session, collection manifests survive deleting
and rebuilding `rag.sqlite`.

Manifest and derived-DB recovery smoke:

```bash
test -f "$ALLBERT_HOME/rag/collections/user/release-docs.toml"
rm -f "$ALLBERT_HOME/index/rag/rag.sqlite"
run rag rebuild --collection-type user --collection release-docs --no-vectors
run rag collections search release-docs "configure Telegram" --mode lexical
run rag collections delete release-docs
```

Expected: the user manifest is source truth, the derived database is restored
from the manifest, and delete removes the user manifest plus derived RAG rows
without deleting source files.

Trust/refusal smoke:

```bash
run rag collections create bad-scheme --source ftp://example.com/file
run rag collections create bad-host --source https://127.0.0.1/
```

Expected: unsupported URL schemes and local/private URL targets are rejected.
For local-path refusal, choose a file outside every configured
`security.fs_roots` entry and verify collection creation or ingest fails with a
trusted-root error. Do not use your real profile for destructive refusal tests.

Multiple-source smoke:

```bash
run rag collections create release-multi \
  --source docs/operator/rag.md \
  --source docs/operator/telegram.md
run rag collections ingest release-multi --no-vectors
run rag collections search release-multi "Telegram RAG status" --mode lexical
run rag collections delete release-multi
```

Expected: one user collection can materialize multiple source URIs, search
results remain scoped to that collection, and source ids are stable across
delete/recreate with the same source set.

First-party RAG skill smoke in a local REPL/TUI session:

```text
Use the rag skill to create a collection named release-docs from docs/operator,
ingest it without vectors, search it for Telegram, attach it to this session,
then detach it and delete it.
```

Expected: the session invokes the `rag` skill, lifecycle mutations route through
kernel-services tools, user snippets appear only after attachment, detach stops
future prompt injection, and delete keeps the source files intact.

What to verify:

- The `rag` skill uses only `list_rag_collections`, `create_rag_collection`,
  `ingest_rag_collection`, `search_rag`, `attach_rag_collection`,
  `detach_rag_collection`, and `delete_rag_collection`.
- The model cannot use the skill to ingest outside trusted roots, fetch blocked
  URLs, search review-only staged memory as ordinary evidence, or attach a user
  collection without explicit operator intent.
- Attached collections persist in the session snapshot until detach, delete, or
  session reset; they should not silently attach to unrelated sessions.

v0.15 M7 URL collection smoke:

```bash
run rag collections create release-web --source https://example.com/
run rag collections ingest release-web --no-vectors
run rag rebuild --collection-type user --collection release-web --vectors
run rag search "example domain" --collection-type user --collection release-web
run rag collections delete release-web
```

Expected: URL ingestion is exact-URL by default, records final URL/HTTP status
and validator metadata when available, honors robots.txt, caps bytes/pages/time,
and rejects unsupported schemes, embedded credentials, localhost, loopback,
link-local/private targets, cloud-metadata targets, and unsafe redirects. Plain
HTTP is either rejected by policy or recorded with a visible degraded/insecure
posture.

What to verify:

- HTTPS URL ingestion does not use browser cookies, credentials, JavaScript
  execution, or authenticated sessions.
- Source status distinguishes active, skipped, and error states. A robots
  refusal, content-type refusal, timeout, or byte cap should be reported as
  source posture, not as a panic.
- Conditional refresh stores and reuses `ETag` or `Last-Modified` when the
  server provides them; otherwise content hash/stale detection still works.
- Same-origin expansion stays bounded by configured depth/page caps and is not
  ambient crawling.

Current v0.15 closeout checklist:

- Provider-free gate from v0.9 and v0.14.2 passes.
- Provider-free lexical RAG rebuild/search/status passes.
- Local Ollama `embeddinggemma` vector smoke passes on a machine with Ollama.
- Local user collection create/ingest/search/delete passes.
- HTTPS URL collection ingest/search/delete passes.
- First-party `rag` skill can create, search, attach, detach, and delete a user
  collection in a local session without bypassing trust policy.
- Telegram remains read-only for RAG status/search.
