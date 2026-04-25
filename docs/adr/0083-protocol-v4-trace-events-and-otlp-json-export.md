# ADR 0083: Protocol v4 trace events and OTLP-JSON export

Date: 2026-04-25
Status: Accepted

## Context

v0.12.1 introduces protocol v3 for live `ActivitySnapshot` and activity update visibility. v0.12.2 needs trace/replay messages without breaking shipped clients or making frontends infer spans locally. It also needs a path for advanced operators to export traces to their own observability stack without coupling Allbert to remote network exporters.

OpenTelemetry is the right export alignment target, but its GenAI semantic conventions are still in Development. Allbert needs a stable internal replay schema even if external attribute names evolve.

## Decision

v0.12.2 bumps the daemon protocol from `3` to `4` additively. A v4 daemon accepts client protocol versions `2`, `3`, and `4`, records the negotiated protocol per connection, and filters outbound messages and fields per peer:

- v2 peers receive only v2-safe messages and fields.
- v3 peers receive v0.12.1 activity messages and fields, but no v4 trace messages.
- v4 peers receive trace span messages, trace read responses, and trace session summaries.

Unsupported versions below `2` or above `4` receive `ProtocolError { code: "version_mismatch", ... }` with remediation that names whether to upgrade the client or daemon. A v4 client connected to a v3 daemon must surface `upgrade the daemon to v0.12.2 to use trace surfaces` and must not synthesize spans locally.

The v4 surface is additive and includes span types, `ServerMessage::TraceSpan` completed-span broadcasts, trace read/list requests, one-span detail requests, and trace read/list responses. `SpanEvent` remains the name for events nested inside a span, not the daemon broadcast message. Live trace broadcast is optional for subscribers; durable replay remains file-backed through ADR 0081.

OTLP export is file-only in v0.12.2. `allbert-cli trace export <session> --format otlp-json` writes an OTLP/JSON trace payload under `ALLBERT_HOME/exports/traces` by default, using `trace.otel_export_dir` only when the configured directory stays inside `ALLBERT_HOME`. `--out` may override the export path, but the resolved path must still remain under `ALLBERT_HOME`. Absolute paths and path escapes are rejected. No HTTP/gRPC/network exporter ships in v0.12.2.

Allbert's internal JSONL trace schema is the durable replay contract. The OTLP-JSON exporter maps internal spans to the current OTLP trace payload shape and the current OpenTelemetry GenAI semantic convention names at export time. If GenAI conventions change, the exporter mapping can change without migrating historical internal trace files unless the Allbert schema itself changes.

## Consequences

**Positive**

- v0.12.2 does not strand v2/v3 clients immediately after the v0.12.1 protocol bump.
- Frontends consume daemon-owned trace truth instead of reconstructing spans locally.
- Operators with existing observability stacks get a portable file export without adding outbound network policy.

**Negative**

- Per-peer filtering increases protocol test surface.
- OTel GenAI alignment requires periodic review while the conventions remain Development.

**Neutral**

- Network OTLP export is explicitly deferred.
- OTLP export is not the source of truth for replay; session JSONL is.

## References

- [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)
- [OpenTelemetry OTLP specification](https://opentelemetry.io/docs/specs/otlp/)
- [docs/plans/v0.12.1-operator-ux-polish.md](../plans/v0.12.1-operator-ux-polish.md)
- [docs/plans/v0.12.2-tracing-and-replay.md](../plans/v0.12.2-tracing-and-replay.md)
- [ADR 0075](0075-session-telemetry-is-kernel-owned-protocol-state.md)
- [ADR 0081](0081-durable-session-trace-artifacts-and-replay-envelope.md)
- [ADR 0082](0082-trace-capture-privacy-and-redaction-posture.md)
