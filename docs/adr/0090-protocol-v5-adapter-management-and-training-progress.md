# ADR 0090: Protocol v5 adapter management and training progress

Date: 2026-04-26
Status: Accepted

Amends: [ADR 0075](0075-session-telemetry-is-kernel-owned-protocol-state.md)

## Context

v0.12.1 added protocol v3 live activity snapshots. v0.12.2 added protocol v4 trace and replay messages. v0.13 adds local adapter training, review, activation, and live training progress. Those are daemon-owned runtime facts: frontends need to render them, but they must not infer adapter state, training phase, or activation status locally.

The protocol decision needs to stay additive. Operators may have older TUI/CLI clients attached to a newer daemon during source-based upgrades, and v0.13 should not break the shipped v2, v3, or v4 client surfaces.

## Decision

v0.13 bumps the daemon protocol to `5`. Protocol v5 adds adapter-management requests and adapter/training responses on top of the v4 trace surface.

### Client messages

Protocol v5 adds adapter requests for:

- list, show, activate, deactivate, remove, status, and history;
- on-demand training start and cancel;
- external adapter install/quarantine.

Older clients do not send these messages. A v5 client connected to an older daemon must fail with an actionable version mismatch and remediation text such as `upgrade the daemon to v0.13 to use adapter surfaces`.

### Server messages

Protocol v5 adds:

- adapter list/show/status/history payloads;
- active-adapter payloads;
- `AdapterTrainingProgress` while a run is active;
- `AdapterTrainingFinal` when a run succeeds, fails, is cancelled, or exceeds the compute cap.

`ActivityPhase::Training` is the live operational truth for "training is happening now." Frontends render that phase from daemon-owned `ActivitySnapshot` data. They do not synthesize training phases, stuck hints, adapter state, or activation status from local timers, command names, or filesystem scans.

Durable training history is not a new protocol-owned trace store. Training spans remain v0.12.2 session trace artifacts (`run_training`, `corpus_assembly`, `trainer_invocation`, `eval_run`) and use the existing trace read/export APIs. Protocol v5 only adds the live adapter-management and progress surface.

### Compatibility

v5 daemons accept v2, v3, v4, and v5 clients. The daemon tracks the negotiated protocol per connection and filters outbound messages per peer:

- v2 peers receive neither v3 activity, v4 trace, nor v5 adapter messages;
- v3 peers receive activity messages but not trace or adapter messages;
- v4 peers receive activity and trace messages but not adapter messages;
- v5 peers receive the full v5 surface subject to normal authorization and trace subscription rules.

The daemon must also suppress v5-only fields from older payloads if a payload type is reused. Unsupported future clients and clients older than the minimum supported protocol receive the existing actionable mismatch response; the daemon must not silently downgrade by fabricating state.

### Ownership

Protocol DTOs live in `allbert-proto`. On-disk adapter manifest validation and schema-version checks live in the kernel adapter manifest module, with explicit conversions to protocol DTOs. This prevents the wire schema from becoming the persistence authority for host-specific adapter artifacts.

## Consequences

**Positive**

- v0.13 adapter surfaces remain daemon-owned and frontend-consistent.
- Older clients keep working during source-based upgrade windows.
- Live progress and durable replay stay separate: protocol v5 for live adapter state, v0.12.2 traces for after-the-fact investigation.

**Negative**

- Daemon broadcast filtering gains one more protocol generation to test.
- Adapter DTOs duplicate parts of the on-disk manifest. Acceptable: persistence and wire compatibility have different stability requirements.

**Neutral**

- This ADR does not change protocol v4 trace semantics.
- Future adapter capabilities should continue to add protocol messages only when a frontend needs live daemon-owned state.

## References

- [docs/plans/v0.13-personalization.md](../plans/v0.13-personalization.md)
- [ADR 0075](0075-session-telemetry-is-kernel-owned-protocol-state.md)
- [ADR 0083](0083-protocol-v4-trace-events-and-otlp-json-export.md)
- [ADR 0084](0084-personality-adapter-job-is-a-learning-job-with-an-owned-trainer-trait.md)
- [ADR 0085](0085-adapter-activation-is-local-only-and-base-model-pinned.md)
