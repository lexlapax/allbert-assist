# ADR 0013: Clients attach to a daemon-hosted kernel via channels

Date: 2026-04-18
Status: Proposed

## Context

Allbert already made a load-bearing architecture choice in v0.1: the kernel is the runtime core and frontends are adapters. The next architectural question is where runtime ownership should live once there are multiple interfaces and background work.

One option would be to let each client keep booting its own private runtime instance. Another option would be to move runtime ownership into a daemon host and let clients attach over channels.

The second option better matches the architecture already chosen and creates the right substrate for channels, sessions, and internal services.

## Decision

Clients will attach to a daemon-hosted kernel via channels.

- The kernel runs inside a local daemon host.
- CLI, REPL, and jobs surfaces attach to the daemon over channels rather than booting their own primary runtime.
- `allbert-cli` and `allbert-jobs` become thin clients.
- The daemon owns session runtime and mediates event, confirm, and input flow for attached clients.
- Jobs are not a privileged kernel mode and not their own host runtime.

## Consequences

**Positive**
- Preserves the kernel-first boundary already established in v0.1.
- Creates a clean substrate for multiple clients and future frontends.
- Keeps scheduler behavior composable with the same tool, hook, memory, and policy surfaces.
- Makes future frontends easier because they attach to the daemon instead of cloning runtime ownership.

**Negative**
- Requires designing and documenting a local control plane.
- Client disconnect, reconnect, and session ownership need careful handling.

**Neutral**
- `allbert-jobs` can still exist as a thin client even though it is no longer a runtime host.
- Future automation or background surfaces can reuse the same attachable-channel pattern rather than inventing a new runtime boundary.

## References

- [ADR 0001](0001-kernel-is-runtime-core-frontends-are-adapters.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
