# Tracing operator guide

v0.12.2 adds durable, local session traces for after-the-fact replay. Live status still comes from daemon-owned telemetry and activity snapshots; traces answer what happened in a completed or in-progress session.

v0.14 self-diagnosis consumes these same trace artifacts through bounded, redacted diagnostic bundles. It does not add another trace persistence location or change trace retention.

## Commands

Use the REPL or TUI slash command when attached to the daemon:

```text
/trace show
/trace show <session-id>
/trace show-span <span-id>
/trace tail
/trace export <session-id>
/trace settings
```

Use the CLI for scripts, exports, and retention checks:

```bash
cargo run -p allbert-cli -- trace list
cargo run -p allbert-cli -- trace show
cargo run -p allbert-cli -- trace show-span <span-id> --session <session-id>
cargo run -p allbert-cli -- trace export <session-id> --format otlp-json
cargo run -p allbert-cli -- trace gc --dry-run
cargo run -p allbert-cli -- settings show trace
```

Telegram exposes structural trace summaries only:

```text
/trace last
/trace span <span-id>
```

Telegram trace replies include span names, status, durations, and bounded attributes. They do not stream full prompt, response, tool argument, or tool result text.

## Storage

Session traces live beside the session they describe:

```text
sessions/<session-id>/trace.jsonl
sessions/<session-id>/trace-*.jsonl.gz
sessions/<session-id>/current_spans/*.json
```

These files are continuity-bearing session artifacts. They are included with `sessions/` in profile export and sync by default. The top-level `traces/` directory remains a legacy/debug derived path and should not be treated as continuity state.

## Capture Posture

The default trace posture is useful replay first:

```toml
[trace]
enabled = true
capture_messages = true
session_disk_cap_mb = 50
total_disk_cap_mb = 2048
retention_days = 30

[trace.redaction]
secrets = "always"
tool_args = "capture"
tool_results = "capture"
provider_payloads = "capture"
```

With `capture_messages = true`, traces may include prompts, responses, tool arguments, tool results, routing decisions, timings, and model/provider metadata. This is local profile data; Allbert does not upload traces or export them unless you run an explicit export command.

## Redaction

Secrets are redacted before trace persistence and before export. `trace.redaction.secrets` is read-only and only supports `always`; attempts to set or reset it through `/settings`, `allbert-cli settings`, config, or bypassed config objects still keep the trace writer's secret redactor active.

The built-in redactor covers common provider and SDK key shapes, including OpenAI, Anthropic, OpenRouter, Slack, GitHub, GitLab, Google, Hugging Face, Stripe, AWS access keys, JWTs, bearer headers, and env-style credential assignments. Detected secrets are replaced with `<redacted:secret>`.

Model output text is not automatically redacted unless it matches a secret pattern. Lower the capture fidelity when you do not want raw prompt, response, tool argument, or tool result text on disk.

## Lower-Fidelity Modes

Inspect the current trace settings:

```text
/settings show trace
```

Disable message capture while keeping structural trace replay:

```text
/settings set trace.capture_messages false
```

When `trace.capture_messages = false`, capture policies that would store full tool args, tool results, or provider payloads are coerced to summary for that load without rewriting the operator's partial `[trace]` block.

Tune individual fields:

```text
/settings set trace.redaction.tool_args summary
/settings set trace.redaction.tool_results drop
/settings set trace.redaction.provider_payloads summary
```

Policies mean:

- `capture`: store the value after secret redaction.
- `summary`: store size/hash metadata instead of full text.
- `drop`: omit the value and store a dropped marker.

## Retention

Trace retention has two bounds:

- per-session cap: `trace.session_disk_cap_mb`
- profile-wide cap and age: `trace.total_disk_cap_mb`, `trace.retention_days`

Preview cleanup before applying it:

```bash
cargo run -p allbert-cli -- trace gc --dry-run
```

Trace GC removes trace artifacts only. It must not remove journals, approvals, metadata, or other unrelated session files.

## Export

OTLP-JSON export is file-only and stays under `ALLBERT_HOME`:

```bash
cargo run -p allbert-cli -- trace export <session-id> --format otlp-json
```

Allbert aligns exported trace fields with OpenTelemetry where practical, but its internal trace schema remains the stable replay contract.

## Related Docs

- [Telemetry operator guide](telemetry.md)
- [TUI operator guide](tui.md)
- [Continuity and sync posture](continuity.md)
- [Self-diagnosis and local utilities](self-diagnosis-and-utilities.md)
