# ADR 0081: Durable session trace artifacts and replay envelope

Date: 2026-04-25
Status: Accepted

## Context

v0.12.1 makes Allbert legible while work is happening through daemon-owned `ActivitySnapshot` state. v0.12.2 needs after-the-fact replay: operators should be able to ask what happened in a session, which model/tool/skill work ran, how long each phase took, and what v0.14 self-diagnosis can read later.

The existing top-level `~/.allbert/traces/` path is debug/trace output from earlier releases and is classified as derived in ADR 0061. It is not a stable replay envelope and is intentionally excluded from profile export/sync. v0.12.2 needs a session-local durable artifact that travels with the session.

## Decision

v0.12.2 stores durable span traces as session artifacts:

```text
~/.allbert/sessions/<session_id>/trace.jsonl
~/.allbert/sessions/<session_id>/trace.<n>.jsonl.gz
~/.allbert/sessions/<session_id>/current_spans/<span_id>.json
```

`trace.jsonl` is append-only and line-oriented. Each completed span is written as one `TraceRecord` JSON object with an Allbert-owned `schema_version`, `record_type = "span"`, and a span payload containing span id, parent id, session id, trace id, span name, kind, timestamps, duration, status, attributes, and events. The persisted record envelope is separate from the live protocol `Span` payload so file-format migrations are explicit. The schema tolerates additive attributes and events; schema-breaking changes require a version bump and reader compatibility tests.

`current_spans/` is crash-recovery state only. On daemon start, leftover in-flight span snapshots are finalized with a `truncated_at_restart` error/event, appended to `trace.jsonl`, and removed from `current_spans/`.

Rotation is per session. When the active file exceeds `trace.session_disk_cap_mb`, it rotates to `trace.<n>.jsonl.gz` and a fresh `trace.jsonl` starts. Trace readers load rotated gzip archives plus the active file, order spans by timestamp with span id as a stable tie-breaker, skip malformed trailing JSONL records with a warning, and reject unsupported future schema versions with remediation. Per-session cap enforcement removes oldest rotated trace archives first. Total trace cap enforcement removes trace artifacts from oldest sessions first. Trace GC may remove only trace artifacts: it must not remove `turns.md`, `meta.json`, approvals, patch artifacts, attachments, or other session files.

Session trace artifacts are continuity-bearing. `profile export` and filesystem sync include `sessions/*/trace.jsonl`, rotated trace archives, and recoverable `current_spans/` state with the rest of `sessions/` by default. Export manifests should report trace counts and byte totals so operators can understand archive size and sensitivity. Top-level `~/.allbert/traces/` remains derived legacy/debug output and stays excluded.

## Consequences

**Positive**

- Replay is local to the session it explains.
- Profile export/import carries trace history needed for cross-device replay and v0.14 self-diagnosis.
- Trace retention and GC have a precise ownership boundary.

**Negative**

- Profile exports may become larger and more sensitive because session traces can include prompts, responses, and tool payloads subject to ADR 0082.
- The trace writer must be careful not to corrupt session directories when cap enforcement runs.

**Neutral**

- Top-level `traces/` remains available for legacy/debug output but is not the v0.12.2 replay contract.
- External observability export is separate from durable replay and is covered by ADR 0083.

## References

- [docs/plans/v0.12.2-tracing-and-replay.md](../plans/v0.12.2-tracing-and-replay.md)
- [docs/plans/v0.14-self-diagnosis.md](../plans/v0.14-self-diagnosis.md)
- [ADR 0049](0049-session-durability-is-a-markdown-journal.md)
- [ADR 0061](0061-local-only-continuity-posture.md)
- [ADR 0082](0082-trace-capture-privacy-and-redaction-posture.md)
- [ADR 0083](0083-protocol-v4-trace-events-and-otlp-json-export.md)
