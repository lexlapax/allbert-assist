# ADR 0023: Local IPC trust is filesystem-scoped; no token auth in v0.2

Date: 2026-04-18
Status: Accepted

## Context

ADR 0020 selected local IPC with client auto-spawn as the v0.2 control-plane default, but it did not address who is allowed to connect. Given v0.1's "security at the core" principle, the daemon's trust posture is load-bearing: the daemon owns kernel sessions, can run tools, can spawn subprocesses, and can read/write files under trusted roots. Any caller that connects speaks with full runtime authority.

Options considered for v0.2:

1. **Filesystem-scoped trust.** The Unix domain socket (or Windows named pipe) lives in a user-owned directory with permissions that restrict access to the local user. Any process that can open the socket is trusted as the user.
2. **Token handshake over local IPC.** Each client presents a shared secret read from a local file. Adds a layer of protection against foothold processes running as the same user.
3. **Per-client capability tokens.** Different clients get different scopes. Much larger design space.

For v0.2, filesystem-scoped trust is the right default:

- Allbert is local-user scoped by design and will not be network-addressable in v0.2.
- The threat model does not attempt to defend against processes already running as the same local user — those processes can already read the user's files, bootstrap files, and API keys directly.
- Token handshakes add complexity without changing the meaningful trust boundary, which is "are you this user or not."
- Capability tokens are a real future direction but require a much richer policy surface than v0.2 needs.

This ADR makes the default explicit so it is not rediscovered as an ambiguity during implementation.

## Decision

Local IPC trust is filesystem-scoped in v0.2. No token authentication, no client capability tokens.

### Unix (macOS, Linux)

- Daemon socket path: `~/.allbert/run/daemon.sock`.
- `~/.allbert/run/` is created with mode `0700` (user-only).
- The socket itself is created with mode `0600` (user read/write only).
- The daemon refuses to start if the parent directory or socket has broader permissions than above; it either corrects them or exits with an actionable error.
- On startup, the daemon detects stale sockets by attempting a connect, and only unlinks and recreates when the connect fails.

### Windows

- Daemon uses a named pipe (path TBD at implementation time, under the user profile).
- The pipe is created with an ACL restricted to the current user SID.
- Cross-platform semantics match: only the local user can connect.

### Client behavior

- Clients connect over the local IPC transport only. No TCP fallback in v0.2.
- Clients do not present tokens; authorization is implicit in the ability to open the endpoint.
- Auto-spawn (ADR 0020) still applies: if the endpoint is missing, the client starts the daemon and reconnects.

### What this ADR does not change

- Tool-level policy still runs. Security hooks, `exec_policy`, `web_policy`, and confirm-trust (ADRs 0004/0007/0009) remain in force on every turn regardless of which channel issued the request.
- Jobs still fail closed on interactive actions (ADR 0015). IPC trust is about "can you talk to the daemon," not "can the daemon run anything without policy checks."

## Consequences

**Positive**
- Matches the local-first, single-user v0.2 product shape.
- Keeps the control-plane implementation small.
- Aligns the trust model with the filesystem permissions users already rely on for `~/.allbert/`.
- Leaves tool/hook-level policy as the real enforcement layer, unchanged from v0.1.

**Negative**
- Any process running as the same user has full daemon authority. Users running untrusted code as themselves should know this.
- Permission drift on `~/.allbert/run/` or the socket could cause daemon startup failures; needs clear messaging.

**Neutral**
- A future release can layer a token handshake or capability tokens on top of this transport without breaking the default.
- Multi-user workstation setups are out of scope for v0.2 regardless; future work there can introduce per-user daemon isolation or richer auth.

## References

- [ADR 0004](0004-process-exec-uses-direct-spawn-and-central-policy.md)
- [ADR 0007](0007-session-scoped-exact-match-confirm-trust.md)
- [ADR 0009](0009-v0-1-tool-surface-expansion-and-policy-envelope.md)
- [ADR 0015](0015-scheduled-jobs-fail-closed-on-interactive-actions.md)
- [ADR 0020](0020-local-ipc-with-client-auto-spawn-is-the-v0-2-control-plane-default.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
