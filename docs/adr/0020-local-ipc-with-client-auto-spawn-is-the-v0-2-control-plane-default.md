# ADR 0020: Local IPC with client auto-spawn is the v0.2 control-plane default

Date: 2026-04-18
Status: Accepted

## Context

Once the daemon owns runtime state, clients need a way to attach. The main choices are local IPC, localhost network protocols, or both. A local-first technical-user tool does not need a network-first control plane in v0.2, and adding one would expand scope into remote transport, auth posture, and broader gateway semantics.

There is also a usability choice: should users start the daemon manually every time, or should clients try to connect and only spawn it when needed?

## Decision

v0.2 uses local IPC with client auto-spawn as the default control plane.

- Clients connect over local IPC first.
- If the daemon is missing, clients attempt to spawn it and then reconnect.
- The protocol should be versioned and framed from day one.
- The daemon remains local-user scoped in v0.2 rather than network-addressable.

## Consequences

**Positive**
- Matches the local-first product shape.
- Keeps normal client usage simple without requiring permanent daemon setup.
- Avoids introducing a remote control plane before it is needed.

**Negative**
- Auto-spawn needs reliable failure handling and clear user messaging.
- Cross-platform local IPC details become part of the implementation surface.

**Neutral**
- A later release could still add another transport if it becomes necessary.
- This ADR does not decide the exact framing format, only the local-first transport posture and auto-spawn default.

## References

- [docs/vision.md](../vision.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
