# ADR 0097: Daemon adapter handlers bridge to the local AdapterStore

Date: 2026-04-26
Status: Accepted
Amends: [ADR 0090](0090-protocol-v5-adapter-management-and-training-progress.md)

## Context

v0.13 declared protocol v5 with adapter management and training-progress messages ([ADR 0090](0090-protocol-v5-adapter-management-and-training-progress.md)). The CLI commands shipped against the existing local `AdapterStore`, adapter runtime helpers, and `PersonalityAdapterJob` paths. They work because they read and write disk directly.

The daemon-side handler at [`server.rs:1183-1205`](../../crates/allbert-daemon/src/server.rs) was left as a stub:

```rust
ClientMessage::AdaptersList
| ClientMessage::AdaptersShow(_)
| ...
| ClientMessage::AdaptersInstallExternal(_) => {
    if client_protocol < 5 { send_adapter_protocol_error(&mut framed).await?; continue; }
    send_server_message(&mut framed, &ServerMessage::Error(ProtocolError {
        code: "adapter_surface_not_implemented".into(),
        message: "adapter surfaces are reserved for v0.13 implementation milestones after M0".into(),
    })).await?;
}
```

This means TUI, Telegram, classic REPL, and any future channel that talks to the daemon over protocol v5 cannot reach adapter state. Only the CLI works, and only because it bypasses the daemon. The result is an architecturally inconsistent v0.13 surface.

## Decision

The v0.14.1 daemon implements every v5 adapter message by delegating to the same disk-backed adapter APIs the CLI uses. The daemon is a thin RPC bridge. It does not own a second adapter database, does not duplicate manifest logic, and does not introduce a new protocol version.

Per-message handlers:

| Client message | Daemon action |
| --- | --- |
| `AdaptersList` | construct `AdapterStore` from daemon paths; call `list()`; return adapter manifests |
| `AdaptersShow(id)` | call `AdapterStore::show(id)`; return manifest or a not-found error |
| `AdaptersActivate(req)` | call the existing `activate_adapter(&store, &config.model, id, override_reason)` helper so base-model pinning and `needs-attention` refusal stay centralized |
| `AdaptersDeactivate` | call `deactivate_adapter(&store, Some("daemon request"))`; broadcast updated active-adapter state |
| `AdaptersRemove(req)` | call `AdapterStore::remove(id, force)`; preserve active-adapter refusal without force |
| `AdaptersStatus` | aggregate today's compute, active adapter, last run/history, and configured training posture using existing store/history/compute helpers |
| `AdaptersHistory(limit)` | call `AdapterStore::history(limit)`; return newest-first entries |
| `AdaptersTrainingStart(req)` | spawn a supervised background task that runs `PersonalityAdapterJob` through the v0.14.1 production trainer factory ([ADR 0098](0098-adapter-trainer-factory-selects-from-config.md)); emit `AdapterTrainingProgress` and `AdapterTrainingFinal` |
| `AdaptersTrainingCancel(run_id)` | look up the active-training registry entry by run id, signal its cancellation token, and return a clear not-found response if no active task exists |
| `AdaptersInstallExternal(req)` | copy/quarantine into `adapters/incoming/` and generate the existing `adapter-approval` flow |

Background training uses the daemon's existing task-supervision posture ([ADR 0019](0019-v0-2-services-are-supervised-in-process-tasks-with-future-subprocess-seams.md)). The daemon keeps an in-memory active-training registry keyed by run id. Each entry contains the task handle, cancellation token, and peer subscription metadata needed for progress/final messages. The registry is runtime coordination only; disk-backed run manifests and adapter history remain the durable source of truth.

Per-peer protocol filtering preserves the existing v2/v3/v4-vs-v5 boundary:

- v5+ peers receive adapter responses and training progress.
- v2/v3/v4 peers never receive adapter-only server messages.
- older peers that send adapter requests receive `version_mismatch` with the existing upgrade remediation.

## Consequences

- TUI, Telegram, classic REPL, and future channels reach the same adapter state the CLI does.
- The CLI can continue to use direct disk-backed commands or later migrate to daemon calls without changing storage semantics.
- No new adapter state lives durably in the daemon.
- Adapter-management tests can now run at the daemon protocol level.
- The "v0.13 protocol v5 adapter management" claim becomes true only after v0.14.1 lands; until then it remains partial as of v0.14 and tracked by v0.14.1.

## Alternatives considered

- **Daemon-owned adapter state.** Rejected because it duplicates the disk-backed store and creates a second source of truth.
- **Defer adapter daemon protocol to v0.15.** Rejected because protocol v5 messages are already in the wire format; the gap is implementation, not design.
- **Remove v5 adapter messages until functional.** Rejected because v5 is already shipped; removing messages would be a protocol break.
