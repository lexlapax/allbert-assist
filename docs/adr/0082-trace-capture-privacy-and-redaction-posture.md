# ADR 0082: Trace capture, privacy, and redaction posture

Date: 2026-04-25
Status: Accepted

> **Amended in v0.14**: self-diagnosis reads trace data through bounded diagnostic bundles and re-runs the secret redactor before report or prompt inclusion as a defensive pass. This does not change v0.12.2 capture defaults, Telegram structural-only limits, or the rule that secret redaction is unconditional before write/export. See [ADR 0091](0091-self-diagnosis-uses-bounded-trace-bundles-and-existing-remediation-surfaces.md).

## Context

Trace replay is most useful when it captures the actual prompt, response, tool arguments, tool results, and provider payloads that shaped a turn. Allbert is a local personal assistant, so the operator owns this data. But trace persistence also increases the amount of sensitive local state, especially when session traces travel through profile export/sync under ADR 0081.

v0.12.2 therefore needs explicit capture defaults, redaction rules, channel-display limits, and upgrade/default-write behavior before implementation begins.

## Decision

The default trace posture is:

```toml
[trace]
enabled = true
capture_messages = true

[trace.redaction]
secrets = "always"
tool_args = "capture"
tool_results = "capture"
provider_payloads = "capture"
```

`capture_messages = true` is the default because replay should answer what happened without forcing operators to preconfigure a low-fidelity diagnostic mode. Operators can lower fidelity by setting `capture_messages = false`, disabling tracing, or setting per-field policies to `summary` or `drop`.

Secret redaction is unconditional and runs before persistence, summary/drop handling, display, or export. `trace.redaction.secrets` is read-only, has the only valid value `always`, and any attempt to set `never` is rejected with operator-visible remediation. The default redactor starts with a bounded pattern allowlist for common provider keys, API keys, tokens, JWTs, and env-style credential assignments, and is wrapped behind a `SecretRedactor` trait so coverage can grow without changing trace storage.

Per-field policy is:

- `capture`: persist the value after secret redaction.
- `summary`: persist a bounded summary plus original length/size metadata.
- `drop`: omit the value and record a dropped marker.

When `capture_messages = false`, loaded `capture` policies for `tool_args`, `tool_results`, and `provider_payloads` are coerced to `summary` for that boot. The coercion is not written back to `config.toml`; `/settings show trace` explains the effective value.

Telegram trace commands are structural-only regardless of capture settings. They may show span names, durations, counts, statuses, and high-level labels, but must not inline raw prompt text, response text, full tool arguments, full tool results, or provider payloads.

Existing-profile `[trace]` default-write is a documented configuration-scaffolding exception. If `config.toml` has no `[trace]` table, the daemon may insert the default block only through the v0.12.1 typed, allowlisted, path-preserving TOML writer. If safe insertion cannot preserve unrelated comments and paths, the daemon skips the write, loads in-memory defaults for the boot, and logs a remediation hint. Partial `[trace]` tables are not auto-rewritten; missing keys load defaults.

## Consequences

**Positive**

- The default trace is useful for replay and self-diagnosis.
- Operators can lower fidelity without disabling tracing entirely.
- Secret redaction cannot be weakened by a mistaken setting.
- Telegram remains safe for compact remote inspection.

**Negative**

- Local trace files and profile exports may contain sensitive non-secret content by default.
- Redaction is pattern-based and can miss novel secret shapes; tests must keep coverage honest.

**Neutral**

- Model output text is not automatically redacted unless the operator lowers `provider_payloads`.
- The settings hub exposes privacy posture but does not become a generic TOML editor.

## References

- [docs/plans/v0.12.2-tracing-and-replay.md](../plans/v0.12.2-tracing-and-replay.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [ADR 0081](0081-durable-session-trace-artifacts-and-replay-envelope.md)
- [ADR 0083](0083-protocol-v4-trace-events-and-otlp-json-export.md)
