# ADR 0019: v0.2 services are supervised in-process tasks with future subprocess seams

Date: 2026-04-18
Status: Accepted

## Context

Once Allbert has a daemon host, it needs some internal structure. The desired shape is a small micro-kernel-like runtime with lightweight services such as channels, sessions, and job management. The immediate question is whether those should all be separate processes from day one.

Process-heavy isolation would improve fault boundaries, but it would also add IPC overhead, process orchestration, and a much larger v0.2 scope before the service model itself is proven. A lighter first step is to keep services in one process while still designing interfaces that can later move across a process boundary.

## Decision

v0.2 services will be supervised in-process tasks first, with explicit seams for later subprocess extraction.

- Channels, sessions, jobs, and supervision run in one daemon process in v0.2.
- Services should still have clear boundaries and responsibilities.
- Interfaces should make later extraction to subprocesses possible without rewriting the public control-plane contract.
- v0.2 does not attempt a process-heavy service mesh.

## Consequences

**Positive**
- Keeps the first daemon release lighter and easier to ship.
- Preserves the small-runtime goal while still giving services explicit ownership.
- Leaves room for later isolation improvements if they prove valuable.

**Negative**
- A service failure can still affect the wider daemon until stronger isolation is introduced.
- Supervision and shutdown behavior need careful design even in one process.

**Neutral**
- This is a sequencing decision, not a forever prohibition on subprocess services.
- The micro-kernel analogy in v0.2 is about service ownership and seams, not maximal isolation on day one.

## References

- [docs/vision.md](../vision.md)
- [docs/plans/v0.2-scheduled-jobs.md](../plans/v0.2-scheduled-jobs.md)
