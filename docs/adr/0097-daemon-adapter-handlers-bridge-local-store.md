# ADR 0097: Daemon adapter handlers bridge to the local AdapterStore

Date: 2026-04-26
Status: Accepted

## Context

v0.13 declared protocol v5 with adapter management and training-progress messages ([ADR 0090](0090-protocol-v5-adapter-management-and-training-progress.md)). The CLI commands shipped against the existing local `AdapterStore` and `PersonalityAdapterJob` and work correctly because they read disk directly. The daemon-side handler at [`server.rs:1183-1205`](../../crates/allbert-daemon/src/server.rs) was left as a `not_implemented` stub:

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

This means TUI, Telegram, classic REPL, and any future channel that talks to the daemon over protocol v5 cannot reach adapter state. Only the CLI works, and only because it bypasses the daemon. The result is an architecturally inconsistent v0.13 release.

## Decision

The v0.14.1 daemon implements every v5 adapter message by delegating directly to the same `allbert_kernel::adapters` APIs the CLI uses today. The daemon is a thin RPC bridge over the existing local store. It does not own any new adapter state, does not introduce a new event kind, and does not duplicate the CLI's logic.

Per-message handlers:

| Client message | Daemon action |
| --- | --- |
| `AdaptersList` | `AdapterStore::list()` → `ServerMessage::Adapters(Vec<AdapterManifest>)` |
| `AdaptersShow(id)` | `AdapterStore::show(id)` → `ServerMessage::Adapter(AdapterManifest)` |
| `AdaptersActivate(req)` | `AdapterStore::activate(...)` honoring base-model pin, `needs-attention` refusal, and `--override` |
| `AdaptersDeactivate` | `AdapterStore::deactivate()` → updated `ActiveAdapter` broadcast |
| `AdaptersRemove(req)` | `AdapterStore::remove(id, force)` |
| `AdaptersStatus` | aggregate today's compute + active adapter + last training run |
| `AdaptersHistory(limit)` | bounded read of `history.jsonl` newest-first |
| `AdaptersTrainingStart(req)` | spawn a background task that runs `PersonalityAdapterJob` via the v0.14.1 trainer factory ([ADR 0098](0098-adapter-trainer-factory-selects-from-config.md)); emit `AdapterTrainingProgress` and `AdapterTrainingFinal` from the existing `KernelEvent` stream |
| `AdaptersTrainingCancel(run_id)` | SIGTERM via existing cancellation token |
| `AdaptersInstallExternal(req)` | quarantine into `adapters/incoming/`, generate `adapter-approval` |

Per-peer protocol filtering preserves the existing v2/v3/v4-vs-v5 boundary: only v5+ peers see adapter responses. v4 peers continue to receive `version_mismatch` with the existing remediation hint.

Background training runs use the daemon's existing task supervision (per [ADR 0019](0019-v0-2-services-are-supervised-in-process-tasks-with-future-subprocess-seams.md)). Cancellation, fail-closed scheduling, daily compute cap, and exec-policy gates remain owned by the kernel — the daemon does not reinvent those.

## Consequences

- TUI, Telegram, classic REPL, and any future channel reach the same adapter state the CLI does.
- The CLI continues to work without change (it can keep talking to disk directly or migrate to the daemon path; both are valid).
- No new adapter state lives in the daemon; the disk is the source of truth.
- Adapter-management tests at the daemon level become possible; v0.13's protocol-level tests stay valid.
- The "v0.13 shipped" claim in roadmap and CHANGELOG becomes accurate after v0.14.1.

## Alternatives considered

- **Daemon-owned adapter state.** Rejected because it duplicates the disk-backed store and creates a second source of truth. The CLI bypass would still work, leading to drift.
- **Defer adapter daemon protocol to v0.15.** Rejected because protocol v5 messages are already in the wire format; v5 clients exist; the gap is implementation, not design.
- **Remove the v5 adapter messages until they are functional.** Rejected because v5 is shipped; removing messages is a protocol break.
