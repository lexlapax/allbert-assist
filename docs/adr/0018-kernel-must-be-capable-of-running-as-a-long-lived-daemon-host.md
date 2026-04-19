# ADR 0018: The kernel must be capable of running as a long-lived daemon host

Date: 2026-04-18
Status: Proposed

## Context

v0.1 proved the kernel can own the agent loop, tools, memory, skills, security, and tracing. What it does not yet provide is a stable runtime host that multiple interfaces can share.

If REPL, CLI, jobs, and later interfaces each boot their own runtime instance, Allbert accumulates duplicated ownership, fragmented session state, and one-off runtime behavior. A daemon-capable host solves that by making runtime ownership explicit and shared.

## Decision

The kernel must be capable of running as a long-lived local daemon host.

- The daemon owns session runtime and lightweight internal services.
- Frontends attach to the daemon instead of each booting their own primary runtime.
- The kernel remains the runtime core inside that host rather than becoming a separate distributed service.
- v0.2 should establish this capability even if later releases deepen it.

## Consequences

**Positive**
- Gives Allbert one local runtime host instead of several private ones.
- Creates the right substrate for attachable channels, background services, and future frontends.
- Keeps runtime ownership explicit and auditable.

**Negative**
- Introduces daemon lifecycle concerns earlier than the old plan did.
- Requires a clearer control-plane contract between clients and the daemon.

**Neutral**
- The daemon can remain single-user and local-first in v0.2.
- This does not require remote networking or a hosted deployment model.

## References

- [docs/vision.md](../vision.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
